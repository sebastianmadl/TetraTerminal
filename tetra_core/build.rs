//! Compiles the vendored ETSI EN 300 395-2 ACELP reference codec (same copy
//! the brew-server uses) into the core library. Works for host builds and for
//! Android NDK / iOS cross-builds, because `cc` picks up the target's C
//! compiler from cargo-ndk / Xcode.
fn main() {
    let src = "third_party/tetra-codec/source";
    println!("cargo:rerun-if-changed={src}");
    println!("cargo:rerun-if-changed=third_party/tetra-codec/include");
    cc::Build::new()
        .file(format!("{src}/tetra-codec.c"))
        .file(format!("{src}/tetra-codec-impl.c"))
        .include(src)
        .include("third_party/tetra-codec/include")
        .warnings(false)
        // The reference code assumes two's-complement wrap-around; clang would
        // otherwise optimise saturation checks away (see L_add / L_sub).
        .flag_if_supported("-fwrapv")
        .opt_level(2)
        .compile("tetra-codec");

    // speexdsp noise suppression (transmit path), see third_party/speexdsp/README.md.
    let spx = "third_party/speexdsp";
    println!("cargo:rerun-if-changed={spx}");
    let mut b = cc::Build::new();
    for f in ["preprocess.c", "filterbank.c", "fftwrap.c", "smallft.c", "mdf.c"] {
        b.file(format!("{spx}/libspeexdsp/{f}"));
    }
    b.include(spx)
        .include(format!("{spx}/include"))
        .include(format!("{spx}/libspeexdsp"))
        .define("HAVE_CONFIG_H", None)
        .warnings(false)
        .opt_level(2)
        .compile("speexdsp");
}
