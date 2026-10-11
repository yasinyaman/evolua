// src/acquire.rs — runtime model acquisition (Faz 4, opt-in `acquire` feature).
//
// Downloads a larger GGUF over HTTPS into the data dir, verifies its SHA-256,
// and places it atomically — so a half-download or a tampered file never
// becomes the live model. The DECISION to upgrade is made in Lua
// (core/modelmgr.lua) under the autonomy ladder; this module is only the safe
// mechanical "go fetch it" step, invoked via the `model_acquire` binding.
//
// The network call is one line in download(); everything that decides whether
// a file becomes the live model is in install(), which the tests below drive
// with in-memory readers.
#![cfg(feature = "acquire")]

use std::io::{Read, Write};
use std::path::Path;

use sha2::{Digest, Sha256};

/// Download `url` → `dest`, optionally checking `sha256` (hex). Atomic on success.
/// A file already at `dest` with the expected checksum is left alone (no re-fetch
/// of GBs every life). Goes through the mesh gateway proxy when one is set.
pub fn download(url: &str, dest: &Path, sha256: Option<&str>) -> anyhow::Result<()> {
    if let (true, Some(expect)) = (dest.exists(), sha256) {
        if let Ok(got) = sha256_of(dest) {
            if got.eq_ignore_ascii_case(expect) {
                return Ok(());
            }
        }
    }
    let agent = crate::netproxy::agent(std::time::Duration::from_secs(10), std::time::Duration::from_secs(600));
    let resp = agent.get(url).call()?;
    install(resp.into_reader(), dest, sha256)
}

fn sha256_of(path: &Path) -> anyhow::Result<String> {
    let mut f = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 1 << 16];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// Stream `reader` into `<dest>.part`, hashing as it goes. Only a non-empty body
/// with the expected checksum replaces `dest` (the previous file is kept as
/// `<name>.prev`, which the Lua `model_rollback` verb puts back). Any failure
/// removes the .part and leaves `dest` untouched.
fn install(reader: impl Read, dest: &Path, sha256: Option<&str>) -> anyhow::Result<()> {
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let tmp = dest.with_extension("part");
    if let Err(e) = write_verified(reader, &tmp, sha256) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    if dest.exists() {
        let bak = dest.with_extension("prev");
        let _ = std::fs::rename(dest, &bak);
    }
    std::fs::rename(&tmp, dest)?;
    Ok(())
}

fn write_verified(mut reader: impl Read, tmp: &Path, sha256: Option<&str>) -> anyhow::Result<()> {
    let mut f = std::fs::File::create(tmp)?;
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
        anyhow::bail!("empty download");
    }
    if let Some(expect) = sha256 {
        let got = format!("{:x}", hasher.finalize());
        if !got.eq_ignore_ascii_case(expect) {
            anyhow::bail!("checksum mismatch: expected {expect}, got {got}");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::install;
    use std::io::Cursor;
    use std::path::PathBuf;

    // a well-formed digest the test body will never hash to
    const NEW_SHA: &str = "5e2a2b5a3a6c2f0d7f8a0b1f1e2a4e3a1c0d9e5f6a7b8c9d0e1f2a3b4c5d6e7f";

    fn sha(data: &[u8]) -> String {
        use sha2::{Digest, Sha256};
        format!("{:x}", Sha256::digest(data))
    }

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("evolua-acquire-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn a_verified_file_replaces_the_model_and_keeps_the_old_one() {
        let d = scratch("ok");
        let dest = d.join("decision.gguf");
        std::fs::write(&dest, b"old model").unwrap();
        install(Cursor::new(b"new model".to_vec()), &dest, Some(&sha(b"new model"))).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"new model");
        assert_eq!(std::fs::read(d.join("decision.prev")).unwrap(), b"old model");
        assert!(!d.join("decision.part").exists());
    }

    #[test]
    fn a_checksum_mismatch_changes_nothing() {
        let d = scratch("bad");
        let dest = d.join("decision.gguf");
        std::fs::write(&dest, b"old model").unwrap();
        let err = install(Cursor::new(b"tampered".to_vec()), &dest, Some(NEW_SHA)).unwrap_err();
        assert!(err.to_string().contains("checksum mismatch"));
        assert_eq!(std::fs::read(&dest).unwrap(), b"old model");
        assert!(!d.join("decision.part").exists(), "no half file left behind");
        assert!(!d.join("decision.prev").exists());
    }

    #[test]
    fn an_empty_body_is_refused() {
        let d = scratch("empty");
        let dest = d.join("decision.gguf");
        assert!(install(Cursor::new(Vec::new()), &dest, None).is_err());
        assert!(!dest.exists() && !d.join("decision.part").exists());
    }

    #[test]
    fn the_checksum_comparison_ignores_case() {
        let d = scratch("case");
        let dest = d.join("decision.gguf");
        install(Cursor::new(b"x".to_vec()), &dest, Some(&sha(b"x").to_uppercase())).unwrap();
        assert!(dest.exists());
    }
}
