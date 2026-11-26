//! Background noise suppression for the transmit path: the speexdsp
//! preprocessor (vendored in `third_party/speexdsp`), denoiser only (its AGC,
//! VAD and dereverb stay off; the app has its own level control).
//!
//! Works on 8 kHz mono PCM in any chunk size and returns exactly as many
//! samples as it was given, delayed by one speex frame ([`LATENCY`]).

use std::collections::VecDeque;
use std::os::raw::{c_int, c_void};

/// Speex frame: 20 ms at 8 kHz.
const FRAME: usize = 160;
/// Delay from input to output in samples.
pub const LATENCY: usize = FRAME;
/// Strongest attenuation of the noise, in dB (speex default is -15).
pub const DEFAULT_SUPPRESS_DB: i32 = -15;

const SET_DENOISE: c_int = 0;
const SET_AGC: c_int = 2;
const SET_VAD: c_int = 4;
const SET_DEREVERB: c_int = 8;
const SET_NOISE_SUPPRESS: c_int = 18;

#[repr(C)]
struct RawState {
    _p: [u8; 0],
}

unsafe extern "C" {
    fn speex_preprocess_state_init(frame_size: c_int, sampling_rate: c_int) -> *mut RawState;
    fn speex_preprocess_state_destroy(st: *mut RawState);
    fn speex_preprocess_run(st: *mut RawState, x: *mut i16) -> c_int;
    fn speex_preprocess_ctl(st: *mut RawState, request: c_int, ptr: *mut c_void) -> c_int;
}

pub struct Denoiser {
    st: *mut RawState,
    input: Vec<i16>,
    output: VecDeque<i16>,
}

// The state is owned by one Denoiser and only touched through &mut self.
unsafe impl Send for Denoiser {}
// No method takes &self, so sharing a reference gives no access to the state.
unsafe impl Sync for Denoiser {}

impl Denoiser {
    /// `suppress_db`: strongest attenuation, negative dB (e.g. -15).
    pub fn new(suppress_db: i32) -> Self {
        let st = unsafe { speex_preprocess_state_init(FRAME as c_int, 8000) };
        assert!(!st.is_null(), "speex_preprocess_state_init failed");
        let ctl = |req: c_int, mut v: c_int| unsafe {
            speex_preprocess_ctl(st, req, &mut v as *mut c_int as *mut c_void);
        };
        ctl(SET_DENOISE, 1);
        ctl(SET_AGC, 0);
        ctl(SET_VAD, 0);
        ctl(SET_DEREVERB, 0);
        ctl(SET_NOISE_SUPPRESS, suppress_db.clamp(-40, -1));
        Self { st, input: Vec::with_capacity(FRAME), output: std::iter::repeat_n(0, LATENCY).collect() }
    }

    /// Denoises `pcm`; the result has the same length, [`LATENCY`] samples late.
    pub fn process(&mut self, pcm: &[i16]) -> Vec<i16> {
        for &s in pcm {
            self.input.push(s);
            if self.input.len() == FRAME {
                unsafe { speex_preprocess_run(self.st, self.input.as_mut_ptr()) };
                self.output.extend(self.input.drain(..));
            }
        }
        self.output.drain(..pcm.len()).collect()
    }
}

impl Drop for Denoiser {
    fn drop(&mut self) {
        unsafe { speex_preprocess_state_destroy(self.st) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rms(x: &[i16]) -> f64 {
        (x.iter().map(|&s| (s as f64).powi(2)).sum::<f64>() / x.len() as f64).sqrt()
    }

    #[test]
    fn keeps_length_and_latency() {
        let mut d = Denoiser::new(DEFAULT_SUPPRESS_DB);
        let mut total = 0;
        for n in [1usize, 37, 160, 333, 7] {
            total += d.process(&vec![100; n]).len();
        }
        assert_eq!(total, 1 + 37 + 160 + 333 + 7);
        let mut d = Denoiser::new(DEFAULT_SUPPRESS_DB);
        let out = d.process(&[1000; LATENCY]);
        assert!(out.iter().all(|&s| s == 0), "the first frame comes out one frame late");
    }

    #[test]
    fn attenuates_steady_noise_but_keeps_a_tone_burst() {
        // 3 s of white-ish noise (LCG), then the same noise plus a loud 500 Hz tone.
        let mut s: u32 = 1;
        let mut noise = || {
            s = s.wrapping_mul(1103515245).wrapping_add(12345);
            ((s >> 16) % 2001) as i32 - 1000
        };
        let quiet: Vec<i16> = (0..24000).map(|_| noise() as i16).collect();
        let loud: Vec<i16> = (0..8000)
            .map(|i| (noise() as f64 + 8000.0 * (2.0 * std::f64::consts::PI * 500.0 * i as f64 / 8000.0).sin()) as i16)
            .collect();
        let mut d = Denoiser::new(DEFAULT_SUPPRESS_DB);
        let q = d.process(&quiet);
        let l = d.process(&loud);
        // Noise alone, after the estimator has settled (last second).
        let reduction = 20.0 * (rms(&q[16000..]) / rms(&quiet[16000..])).log10();
        assert!(reduction < -8.0, "noise only reduced by {reduction:.1} dB");
        // The tone survives (within 3 dB).
        let tone = 20.0 * (rms(&l[1000..]) / rms(&loud[1000..])).log10();
        assert!(tone > -3.0, "tone reduced by {tone:.1} dB");
    }
}
