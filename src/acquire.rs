// src/acquire.rs — runtime model acquisition (Faz 4, opt-in `acquire` feature).
//
// Downloads a larger GGUF over HTTPS into the data dir, verifies its SHA-256,
// and places it atomically — so a half-download or a tampered file never
// becomes the live model. The DECISION to upgrade is made in Lua
// (core/modelmgr.lua) under the autonomy ladder; this module is only the safe
// mechanical "go fetch it" step, invoked via the `model_acquire` binding.
//
// NOTE: this path performs network I/O and cannot be exercised in the offline
// sandbox; it is written against ureq + sha2 and compiled on the user's machine.
#![cfg(feature = "acquire")]

use std::io::{Read, Write};
use std::path::Path;

use sha2::{Digest, Sha256};

/// Download `url` → `dest`, optionally checking `sha256` (hex). Atomic on success.
pub fn download(url: &str, dest: &Path, sha256: Option<&str>) -> anyhow::Result<()> {
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let resp = ureq::get(url)
        .timeout(std::time::Duration::from_secs(600))
        .call()?;
    let mut reader = resp.into_reader();

    let tmp = dest.with_extension("part");
    let mut f = std::fs::File::create(&tmp)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 1 << 16];
    let mut total: u64 = 0;
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        f.write_all(&buf[..n])?;
        total += n as u64;
    }
    f.sync_all()?;
    drop(f);

    if total == 0 {
        let _ = std::fs::remove_file(&tmp);
        anyhow::bail!("empty download from {url}");
    }
    if let Some(expect) = sha256 {
        let got = format!("{:x}", hasher.finalize());
        if !got.eq_ignore_ascii_case(expect) {
            let _ = std::fs::remove_file(&tmp);
            anyhow::bail!("checksum mismatch: expected {expect}, got {got}");
        }
    }

    // keep the previous model as a rollback copy, then swap in atomically
    if dest.exists() {
        let bak = dest.with_extension("prev");
        let _ = std::fs::rename(dest, &bak);
    }
    std::fs::rename(&tmp, dest)?;
    Ok(())
}
