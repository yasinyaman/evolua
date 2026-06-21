// src/supervisor.rs — the host-side autonomic watch (the "brainstem")
//
// A background thread that OBSERVES the in-process Lua organism and reports its
// vitals; it does not steer evolution. Because the organism runs on the main
// thread (mlua is in-process and blocks), this watch lives on its own thread and
// can only talk to the organism the way everything else in EvoLua does — through
// the filesystem (the same "file dance" idiom as approvals and the colony).
//
// Two jobs, both soft:
//   1. liveness — is the tick loop still beating? (watch <state>/heartbeat, which
//      the Lua `supervisor` organ touches every tick; fall back to the log file).
//   2. vitals   — write coarse host facts the organism can't cheaply see about
//      itself (its RSS, how many colony processes are live) to <state>/vitals,
//      for the Lua side to read and REACT to. The response stays in evolvable Lua.
//
// It never caps or kills by default. A last-resort process exit on a prolonged
// stall is available but OPT-IN (EVOLUA_WATCHDOG_KILL=1) — the brainstem's only
// reflex, and even that is off unless asked for. Governance stays in Lua.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn env_secs(key: &str, default: u64) -> u64 {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn now_unix() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

/// Seconds since a file was last modified (None if missing/unreadable).
fn file_age_secs(path: &Path) -> Option<u64> {
    let mtime = fs::metadata(path).ok()?.modified().ok()?;
    SystemTime::now().duration_since(mtime).ok().map(|d| d.as_secs())
}

/// Best-effort RSS (MB) of our own process via `ps` (unix); None elsewhere.
fn self_rss_mb() -> Option<u64> {
    let pid = std::process::id().to_string();
    let out = Command::new("ps").args(["-o", "rss=", "-p", &pid]).output().ok()?;
    String::from_utf8_lossy(&out.stdout).trim().parse::<u64>().ok().map(|kb| kb / 1024)
}

/// Best-effort count of live colony members: processes whose command line
/// mentions our binary. 0 if `ps` is unavailable. A coarse fork-bomb sentinel
/// that the Lua side can compare against its own peer-beacon census.
fn colony_procs(marker: &str) -> u64 {
    match Command::new("ps").args(["-ax", "-o", "command="]).output() {
        Ok(o) => String::from_utf8_lossy(&o.stdout)
            .lines()
            .filter(|l| l.contains(marker))
            .count() as u64,
        Err(_) => 0,
    }
}

fn append(path: &Path, line: &str) {
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{} {}", now_unix(), line);
    }
}

/// Start the watch (no-op if EVOLUA_WATCHDOG=0). Detached: dies with the process.
pub fn spawn(home: PathBuf) {
    if std::env::var("EVOLUA_WATCHDOG").as_deref() == Ok("0") {
        return;
    }
    thread::spawn(move || run(home));
}

fn run(home: PathBuf) {
    let state = home.join("state");
    let _ = fs::create_dir_all(&state);
    let heartbeat = state.join("heartbeat"); // touched by the Lua supervisor organ
    let log_file = state.join("evolua.log"); // fallback liveness signal
    let vitals = state.join("vitals"); // we write this; the Lua side reads it
    let suplog = state.join("supervisor.log");

    let interval = env_secs("EVOLUA_WATCHDOG_SECS", 5).max(1);
    let stall_secs = env_secs("EVOLUA_WATCHDOG_STALL", 30);
    let kill_on = std::env::var("EVOLUA_WATCHDOG_KILL").as_deref() == Ok("1");
    let kill_secs = env_secs("EVOLUA_WATCHDOG_KILL_SECS", 120);

    let marker = std::env::current_exe()
        .ok()
        .and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_string()))
        .unwrap_or_else(|| "evolua".to_string());

    append(&suplog, &format!(
        "supervisor online (interval={interval}s stall={stall_secs}s kill={kill_on})"
    ));

    let mut was_stalled = false;
    loop {
        thread::sleep(Duration::from_secs(interval));

        // liveness: prefer the organ's heartbeat, fall back to the log's mtime
        let age = file_age_secs(&heartbeat).or_else(|| file_age_secs(&log_file));
        let hb_age = age.unwrap_or(u64::MAX);
        let hb_field: i64 = if hb_age == u64::MAX { -1 } else { hb_age as i64 };
        let stalled = age.is_some() && hb_age >= stall_secs;

        let rss = self_rss_mb().unwrap_or(0);
        let procs = colony_procs(&marker);

        let _ = fs::write(&vitals, format!(
            "at={}\nstall={}\nheartbeat_age={}\nself_rss_mb={}\ncolony_procs={}\n",
            now_unix(), if stalled { 1 } else { 0 }, hb_field, rss, procs
        ));

        if stalled && !was_stalled {
            append(&suplog, &format!("WARN organism stalled — no heartbeat for {hb_age}s"));
        } else if !stalled && was_stalled {
            append(&suplog, "INFO organism recovered");
        }
        was_stalled = stalled;

        // last-resort reflex (opt-in): if truly wedged, exit so a launcher can
        // restart. Off by default — supervision, not control.
        if kill_on && age.is_some() && hb_age >= kill_secs {
            append(&suplog, &format!(
                "FATAL last-resort exit: stalled {hb_age}s >= {kill_secs}s"
            ));
            std::process::exit(70);
        }
    }
}
