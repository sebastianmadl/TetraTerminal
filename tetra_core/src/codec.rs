//! TETRA ACELP voice (ETSI EN 300 395-2) via the vendored reference codec,
//! plus the 60 ms framing Brew uses on the wire.
//!
//! Audio contract with the app: 8 kHz, mono, signed 16-bit PCM. The phone
//! side records/plays at 8 kHz (Android AudioRecord/AudioTrack and iOS
//! AVAudioEngine both support it) and exchanges 480-sample (60 ms) blocks.

use crate::protocol::{self, ACELP_CODED_FRAME_BYTES, ACELP_PCM_SAMPLES};
use std::os::raw::c_int;
use uuid::Uuid;

/// Samples in one Brew traffic frame (two ACELP subframes).
pub const FRAME_SAMPLES: usize = 2 * ACELP_PCM_SAMPLES;
pub const SAMPLE_RATE: u32 = 8000;
/// Fade-out applied to the last samples of a transmission (10 ms).
const FADE_SAMPLES: usize = 80;
/// Silent 60 ms blocks sent after the last speech.
const TAIL_SILENCE_BLOCKS: usize = 2;

#[repr(C)]
struct RawCodec {
    _p: [u8; 0],
}

unsafe extern "C" {
    fn tetra_encoder_create() -> *mut RawCodec;
    fn tetra_decoder_create() -> *mut RawCodec;
    fn tetra_codec_destroy(st: *mut RawCodec);
    fn tetra_encode(st: *mut RawCodec, pcm: *const i16, coded: *mut u8);
    fn tetra_decode(st: *mut RawCodec, coded: *const u8, pcm: *mut i16, bfi: c_int);
}

struct Handle(*mut RawCodec);
// Owned by exactly one encoder/decoder, which is moved, never shared.
unsafe impl Send for Handle {}
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { tetra_codec_destroy(self.0) }
    }
}

/// Stateful ACELP encoder: one per outgoing transmission.
pub struct VoiceEncoder {
    h: Handle,
    pending: Vec<i16>,
}

impl Default for VoiceEncoder {
    fn default() -> Self {
        Self::new()
    }
}

impl VoiceEncoder {
    pub fn new() -> Self {
        Self { h: Handle(unsafe { tetra_encoder_create() }), pending: Vec::with_capacity(FRAME_SAMPLES * 2) }
    }

    fn encode_sub(&mut self, pcm: &[i16]) -> [u8; ACELP_CODED_FRAME_BYTES] {
        debug_assert_eq!(pcm.len(), ACELP_PCM_SAMPLES);
        let mut out = [0u8; ACELP_CODED_FRAME_BYTES];
        unsafe { tetra_encode(self.h.0, pcm.as_ptr(), out.as_mut_ptr()) };
        out
    }

    /// Feed any amount of microphone PCM; returns one 36-byte STE payload per
    /// complete 60 ms block. Leftover samples are kept for the next call.
    pub fn push(&mut self, pcm: &[i16]) -> Vec<[u8; protocol::STE_VOICE_PAYLOAD_BYTES]> {
        self.pending.extend_from_slice(pcm);
        let mut out = Vec::new();
        while self.pending.len() >= FRAME_SAMPLES {
            let block: Vec<i16> = self.pending.drain(..FRAME_SAMPLES).collect();
            let a = self.encode_sub(&block[..ACELP_PCM_SAMPLES]);
            let b = self.encode_sub(&block[ACELP_PCM_SAMPLES..]);
            out.push(protocol::pack_ste(&a, &b));
        }
        out
    }

    /// End of transmission. Fades out and pads the trailing partial block with
    /// silence (so the last words are not lost and there is no hard step), then
    /// appends [`TAIL_SILENCE_BLOCKS`] blocks of silence so the far-end decoder
    /// settles instead of glitching on the cut. Returns the final STE payloads.
    pub fn flush(&mut self) -> Vec<[u8; protocol::STE_VOICE_PAYLOAD_BYTES]> {
        let mut out = Vec::new();
        if !self.pending.is_empty() {
            let n = self.pending.len();
            let fade = n.min(FADE_SAMPLES);
            for i in 0..fade {
                let k = n - fade + i;
                self.pending[k] = (self.pending[k] as f32 * (1.0 - (i + 1) as f32 / fade as f32)) as i16;
            }
            let pad = FRAME_SAMPLES - n;
            out.extend(self.push(&vec![0; pad]));
        }
        out.extend(self.push(&vec![0; FRAME_SAMPLES * TAIL_SILENCE_BLOCKS]));
        out
    }

    /// Same as [`push`] but returns ready-to-send Brew frames for call `id`.
    pub fn push_frames(&mut self, id: &Uuid, pcm: &[i16]) -> Vec<Vec<u8>> {
        self.push(pcm)
            .into_iter()
            .map(|p| protocol::build_frame(protocol::FRAME_TRAFFIC_CHANNEL, id, (p.len() * 8) as u16, &p))
            .collect()
    }
}

/// Stateful ACELP decoder: one per incoming transmission.
pub struct VoiceDecoder {
    h: Handle,
}

impl Default for VoiceDecoder {
    fn default() -> Self {
        Self::new()
    }
}

impl VoiceDecoder {
    pub fn new() -> Self {
        Self { h: Handle(unsafe { tetra_decoder_create() }) }
    }

    fn decode_sub(&mut self, coded: &[u8; ACELP_CODED_FRAME_BYTES], bad: bool) -> [i16; ACELP_PCM_SAMPLES] {
        let mut pcm = [0i16; ACELP_PCM_SAMPLES];
        unsafe { tetra_decode(self.h.0, coded.as_ptr(), pcm.as_mut_ptr(), bad as c_int) };
        pcm
    }

    /// Decode one STE payload into 480 samples. A malformed payload runs the
    /// codec's bad-frame concealment instead of producing garbage.
    pub fn decode(&mut self, ste: &[u8]) -> Vec<i16> {
        let (a, b, bad) = match protocol::unpack_ste(ste) {
            Some((a, b)) => (a, b, false),
            None => ([0; ACELP_CODED_FRAME_BYTES], [0; ACELP_CODED_FRAME_BYTES], true),
        };
        let mut out = Vec::with_capacity(FRAME_SAMPLES);
        out.extend_from_slice(&self.decode_sub(&a, bad));
        out.extend_from_slice(&self.decode_sub(&b, bad));
        out
    }

    /// Concealment for a frame that never arrived (jitter buffer underrun).
    pub fn conceal(&mut self) -> Vec<i16> {
        self.decode(&[])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_60ms_blocks_and_decodes_tone() {
        let mut enc = VoiceEncoder::new();
        let tone: Vec<i16> = (0..FRAME_SAMPLES * 5).map(|i| ((i as f32 * 0.15).sin() * 9000.0) as i16).collect();
        // Feed in odd-sized chunks like a real audio callback would.
        let mut frames = Vec::new();
        for chunk in tone.chunks(333) {
            frames.extend(enc.push(chunk));
        }
        assert_eq!(frames.len(), 5);
        let mut dec = VoiceDecoder::new();
        let mut energy = 0i64;
        for f in &frames {
            let pcm = dec.decode(f);
            assert_eq!(pcm.len(), FRAME_SAMPLES);
            energy += pcm.iter().map(|&s| (s as i64).abs()).sum::<i64>();
        }
        assert!(energy > 0, "decoded audio should not be silent");
        assert_eq!(dec.conceal().len(), FRAME_SAMPLES);

        // A trailing partial block is padded out, not dropped.
        let mut enc = VoiceEncoder::new();
        assert!(enc.push(&tone[..100]).is_empty());
        assert_eq!(enc.flush().len(), 1 + TAIL_SILENCE_BLOCKS);
    }

    /// The encoder must produce the reference codec's exact bitstream on every
    /// compiler. Its saturating basic operators (`L_add`, `L_sub`) used to rely on
    /// signed overflow, which clang at -O2 (Xcode, Android NDK) treats as
    /// impossible and optimises away: the phone then sent frames that a radio
    /// decodes with full-scale ~2.7 kHz bursts. Expected digest = the vendored
    /// codec built with gcc -O0, i.e. the code as written.
    #[test]
    fn encoder_is_bit_exact_with_the_reference_build() {
        use md5::{Digest, Md5};
        // Loud, integer-only test signal (sawtooth with changing pitch and level
        // plus noise), so the result does not depend on floating point.
        let mut s: u32 = 12345;
        let pcm: Vec<i16> = (0..8000 * 3)
            .map(|i: i32| {
                let p = 50 + (i / 800) % 30;
                let a = 8000 + 4000 * ((i / 400) % 3);
                s = s.wrapping_mul(1103515245).wrapping_add(12345);
                let noise = ((s >> 16) % 2001) as i32 - 1000;
                ((i % p) * 2 * a / p - a + noise) as i16
            })
            .collect();
        let mut enc = VoiceEncoder::new();
        let mut hash = Md5::new();
        for ste in enc.push(&pcm) {
            let (a, b) = protocol::unpack_ste(&ste).unwrap();
            hash.update(a);
            hash.update(b);
        }
        assert_eq!(hex::encode(hash.finalize()), "26daded48fe3320f90a2608e3f6d97df");
    }
}
