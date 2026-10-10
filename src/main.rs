// EvoLua — single-binary host.
//
// Embeds the Lua organism (lua/) into the executable and runs it in an
// in-process mlua (Lua 5.4, vendored & statically linked) VM. Every embedded
// module is registered into `package.preload`, so the organism's own
// `require("core.kernel")` / `require("config")` calls resolve straight from
// memory — no files on disk, no external `lua` interpreter.
//
// At startup the host resolves an environment-appropriate, writable data
// directory (macOS / Linux / Windows conventions, overridable via $EVOLUA_HOME),
// creates it, and hands it to the organism as the global `EVOLUA_HOME`. That is
// where the organism keeps the plugins it grows, its reports, and its memory.

use std::borrow::Cow;
use std::env;
use std::fs;
use std::path::PathBuf;

use mlua::{Lua, Table};
use rust_embed::RustEmbed;

#[cfg(feature = "llm")]
mod llm;
#[cfg(feature = "acquire")]
mod acquire;
#[cfg(all(feature = "apple", target_os = "macos"))]
mod apple;
mod brain;
mod discover;
mod host;
#[cfg(feature = "service")]
mod service;
mod supervisor;

// Only the organism's SOURCE is embedded: core/, sensors/, config.lua, main.lua.
// A plain-Lua run keeps its runtime artifacts under lua/ (plugins/, state/,
// reports/, …); those must never be compiled as modules (state/memory.lua is a
// bare table, not a chunk) nor shipped inside a release binary.
#[derive(RustEmbed)]
#[folder = "lua/core/"]
#[prefix = "core/"]
struct CoreSrc;

#[derive(RustEmbed)]
#[folder = "lua/sensors/"]
#[prefix = "sensors/"]
struct SensorSrc;

const CONFIG_LUA: &str = include_str!("../lua/config.lua");
const MAIN_LUA: &str = include_str!("../lua/main.lua");

/// (path, source) for every embedded module except main.lua.
fn embedded_modules() -> Vec<(String, Cow<'static, [u8]>)> {
    let mut out = vec![("config.lua".to_string(), Cow::Borrowed(CONFIG_LUA.as_bytes()))];
    for p in CoreSrc::iter() {
        if let Some(f) = CoreSrc::get(&p) {
            out.push((p.into_owned(), f.data));
        }
    }
    for p in SensorSrc::iter() {
        if let Some(f) = SensorSrc::get(&p) {
            out.push((p.into_owned(), f.data));
        }
    }
    out
}

/// Pick a writable home for the organism's body parts & memory.
/// Priority: $EVOLUA_HOME → OS data dir/EvoLua → ./evolua-data (last resort).
fn resolve_home() -> PathBuf {
    if let Some(h) = env::var_os("EVOLUA_HOME") {
        return PathBuf::from(h);
    }
    let os_dir: Option<PathBuf> = if cfg!(target_os = "macos") {
        env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Application Support/EvoLua"))
    } else if cfg!(target_os = "windows") {
        env::var_os("APPDATA").map(|a| PathBuf::from(a).join("EvoLua"))
    } else {
        env::var_os("XDG_DATA_HOME")
            .map(|x| PathBuf::from(x).join("evolua"))
            .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share/evolua")))
    };
    os_dir.unwrap_or_else(|| {
        env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .join("evolua-data")
    })
}

/// "core/kernel.lua" -> "core.kernel", "config.lua" -> "config".
fn module_name(path: &str) -> String {
    path.trim_end_matches(".lua")
        .replace(['/', '\\'], ".")
}

fn run() -> mlua::Result<()> {
    // 1) writable data home, created up front
    let home = resolve_home();
    for sub in ["", "plugins", "reports", "state", "sandbox"] {
        let _ = fs::create_dir_all(home.join(sub));
    }
    let home_str = home.to_string_lossy().to_string();

    // 1b) host-side autonomic watch ("brainstem"): a background thread that
    // observes the organism's liveness + vitals and writes them to <state>/vitals
    // for the Lua side to react to. Soft by design — it never steers evolution.
    supervisor::spawn(home.clone());

    // 2) Lua VM
    let lua = Lua::new();
    let globals = lua.globals();

    // 3) hand the organism its environment
    globals.set("EVOLUA_HOME", home_str.clone())?;
    globals.set("EVOLUA_EMBEDDED", true)?;

    // forward CLI args as the Lua `arg` table (arg[0] = program name)
    let arg_tbl = lua.create_table()?;
    let mut argv = env::args();
    arg_tbl.set(0, argv.next().unwrap_or_else(|| "evolua".to_string()))?;
    for (i, a) in argv.enumerate() {
        arg_tbl.set((i + 1) as i64, a)?;
    }
    globals.set("arg", arg_tbl)?;

    // 3a) native filesystem helpers (host_list_dir / host_walk / host_mkdir /
    // host_cwd) so perception doesn't build shell commands out of path names.
    // core/platform.lua uses them when present, the shell otherwise.
    host::register(&lua)?;

    // 3b) decision brain — host_brain_kinds / _load / _complete / _info. Nothing
    // is loaded here: core/brain.lua picks the brain at boot (an explicit model,
    // else a bigger usable one already on the machine, else the organism's own
    // default — downloaded or embedded) and points the reasoner's llm_complete at it.
    // With no backend compiled in, the reasoner falls back to rules.
    brain::register(&lua, home.clone())?;

    // 3c) model acquisition (Faz 4) — expose model_acquire(url, dest, sha256?).
    // The Lua model manager calls this only after the autonomy ladder approves
    // an upgrade. Absent feature → no global → Lua logs "no acquire binding".
    #[cfg(feature = "acquire")]
    {
        let f = lua.create_function(
            move |_, (url, dest, sha): (String, String, Option<String>)| {
                match acquire::download(&url, std::path::Path::new(&dest), sha.as_deref()) {
                    Ok(()) => Ok(true),
                    Err(e) => {
                        eprintln!("model_acquire error: {e}");
                        Ok(false)
                    }
                }
            },
        )?;
        globals.set("model_acquire", f)?;
    }

    // 4) register every embedded module into package.preload (main.lua runs below)
    let package: Table = globals.get("package")?;
    let preload: Table = package.get("preload")?;
    for (p, data) in embedded_modules() {
        if !p.ends_with(".lua") {
            continue;
        }
        let chunk_name = format!("@{}", p);
        let func = lua.load(&*data).set_name(&chunk_name).into_function()?;
        preload.set(module_name(&p), func)?;
    }

    // 5) breathe life into it
    let mut body = MAIN_LUA.as_bytes().to_vec();
    // The standalone `lua` CLI skips a leading shebang (#!) line; mlua's loader
    // does not. main.lua carries one for plain-`lua` execution, so strip it here
    // (keep the newline to preserve line numbers in any error messages).
    if body.first() == Some(&b'#') {
        if let Some(nl) = body.iter().position(|&b| b == b'\n') {
            body.drain(..nl);
        }
    }
    lua.load(&*body).set_name("@main.lua").exec()?;
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("EvoLua fatal: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::{embedded_modules, module_name, resolve_home};

    #[test]
    fn module_names_follow_require_paths() {
        assert_eq!(module_name("core/kernel.lua"), "core.kernel");
        assert_eq!(module_name("sensors/fswatch.lua"), "sensors.fswatch");
        assert_eq!(module_name("config.lua"), "config");
        assert_eq!(module_name(r"core\kernel.lua"), "core.kernel");
    }

    #[test]
    fn only_organism_source_is_embedded() {
        let paths: Vec<String> = embedded_modules().into_iter().map(|(p, _)| p).collect();
        for want in ["config.lua", "core/kernel.lua", "core/serialize.lua", "sensors/fswatch.lua"] {
            assert!(paths.iter().any(|p| p == want), "missing {want}");
        }
        for p in &paths {
            assert!(p == "config.lua" || p.starts_with("core/") || p.starts_with("sensors/"), "unexpected {p}");
        }
    }

    #[test]
    fn evolua_home_overrides_the_os_default() {
        // the only test that touches EVOLUA_HOME, so no other test races it
        std::env::set_var("EVOLUA_HOME", "/tmp/evolua-test-home");
        assert_eq!(resolve_home(), std::path::PathBuf::from("/tmp/evolua-test-home"));
        std::env::remove_var("EVOLUA_HOME");
        assert_ne!(resolve_home(), std::path::PathBuf::from("/tmp/evolua-test-home"));
    }
}
