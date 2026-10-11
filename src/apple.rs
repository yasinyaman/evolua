// src/apple.rs — macOS's on-device language model as a decision brain
// (feature `apple`, macOS 26+ with Apple Intelligence turned on). The model is
// the system's: nothing is downloaded or loaded into this process, and the OS
// manages its memory. The calls go through the Swift bridge in
// src/apple/bridge.swift, compiled by build.rs.
#![cfg(all(feature = "apple", target_os = "macos"))]

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

extern "C" {
    fn evolua_apple_status() -> i32;
    fn evolua_apple_complete(system: *const c_char, user: *const c_char, max_tokens: i32, err: *mut *mut c_char) -> *mut c_char;
    fn evolua_apple_free(p: *mut c_char);
}

/// "available", or why not: "deviceNotEligible" | "appleIntelligenceNotEnabled" |
/// "modelNotReady" | "unsupported" (macOS < 26) | "unavailable".
pub fn status() -> &'static str {
    match unsafe { evolua_apple_status() } {
        0 => "available",
        1 => "deviceNotEligible",
        2 => "appleIntelligenceNotEnabled",
        3 => "modelNotReady",
        5 => "unsupported",
        _ => "unavailable",
    }
}

/// Take ownership of a C string the bridge allocated.
unsafe fn take(p: *mut c_char) -> String {
    let s = CStr::from_ptr(p).to_string_lossy().into_owned();
    evolua_apple_free(p);
    s
}

pub struct Model;

impl Model {
    pub fn open() -> anyhow::Result<Model> {
        match status() {
            "available" => Ok(Model),
            why => anyhow::bail!("the Apple on-device model isn't usable here: {why}"),
        }
    }

    pub fn complete(&self, system: &str, user: &str, max_tokens: usize) -> anyhow::Result<String> {
        let (s, u) = (CString::new(system)?, CString::new(user)?);
        let mut err: *mut c_char = std::ptr::null_mut();
        let max = max_tokens.min(i32::MAX as usize) as i32;
        // SAFETY: both strings outlive the call; the bridge returns either a
        // malloc'd answer or NULL plus a malloc'd error, each freed by take().
        unsafe {
            let out = evolua_apple_complete(s.as_ptr(), u.as_ptr(), max, &mut err);
            if out.is_null() {
                let why = if err.is_null() { "unknown error".to_string() } else { take(err) };
                anyhow::bail!("Apple on-device model: {why}");
            }
            Ok(take(out))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_is_one_of_the_known_answers() {
        let s = status();
        assert!(
            ["available", "deviceNotEligible", "appleIntelligenceNotEnabled", "modelNotReady", "unsupported", "unavailable"]
                .contains(&s),
            "{s}"
        );
    }

    #[test]
    fn answers_when_available() {
        if status() != "available" {
            return; // CI runners and older Macs: nothing to call
        }
        let m = Model::open().unwrap();
        let text = m.complete("Be terse.", "Reply with exactly: ROUTE: rule", 16).unwrap();
        assert!(text.contains("ROUTE"), "{text}");
    }
}
