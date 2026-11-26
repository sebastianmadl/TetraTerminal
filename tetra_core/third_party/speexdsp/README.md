# speexdsp (subset)

Noise suppression for the transmit path: `speex_preprocess` from
https://github.com/xiph/speexdsp, commit 7a158783df74efe7c2d1c6ee8363c1e695c71226
(2025-07-05), unmodified. Only the files the preprocessor needs are kept
(`mdf.c` because `preprocess.c` links against the echo canceller's residual
function). `config.h` and `include/speex/speexdsp_config_types.h` are written
for this build (float, smallft FFT). BSD licence, see `COPYING`.
