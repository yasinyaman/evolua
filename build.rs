// build.rs — only does work for the `apple` feature on macOS: compiles the
// Swift bridge to the on-device FoundationModels model (src/apple/bridge.swift)
// into a static library and links it. Every other build is plain Cargo.
use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn xcrun(args: &[&str]) -> Option<String> {
    let out = Command::new("xcrun").args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/apple/bridge.swift");
    if env::var_os("CARGO_FEATURE_APPLE").is_none() || env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        other => panic!("`apple` feature: unsupported macOS arch {other:?}"),
    };
    let sdk = xcrun(&["--show-sdk-path"]).expect("`apple` feature: xcrun not found — install Xcode or the Command Line Tools");
    let swiftc = xcrun(&["--find", "swiftc"]).expect("`apple` feature: swiftc not found");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let lib = out.join("libevolua_apple.a");

    // macOS 12+: Swift concurrency ships with the OS, no back-deployment shims.
    // FoundationModels is NOT autolinked (that would be a strong link and stop
    // the binary from starting on macOS < 26); it is weak-linked below instead.
    let status = Command::new(&swiftc)
        .args(["-emit-library", "-static", "-parse-as-library", "-O", "-swift-version", "5"])
        .args(["-module-name", "EvoluaApple", "-target", &format!("{arch}-apple-macos12.0")])
        .args(["-sdk", &sdk])
        .args(["-Xfrontend", "-disable-autolink-framework", "-Xfrontend", "FoundationModels"])
        .arg("src/apple/bridge.swift")
        .arg("-o")
        .arg(&lib)
        .status()
        .expect("`apple` feature: failed to run swiftc");
    assert!(status.success(), "`apple` feature: swiftc failed to build src/apple/bridge.swift");

    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=evolua_apple");
    // the Swift runtime and Foundation are part of macOS
    println!("cargo:rustc-link-search=native={sdk}/usr/lib/swift");
    if let Some(toolchain) = Path::new(&swiftc).parent().and_then(Path::parent) {
        println!("cargo:rustc-link-search=native={}", toolchain.join("lib/swift/macosx").display());
    }
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    println!("cargo:rustc-link-lib=framework=Foundation");
    if Path::new(&sdk).join("System/Library/Frameworks/FoundationModels.framework").exists() {
        println!("cargo:rustc-link-arg=-Wl,-weak_framework,FoundationModels");
    }
}
