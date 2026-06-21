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

use std::env;
use std::fs;
use std::path::PathBuf;

use mlua::{Lua, Table};
use rust_embed::RustEmbed;

#[cfg(feature = "llm")]
mod llm;
#[cfg(feature = "acquire")]
mod acquire;
mod supervisor;

#[derive(RustEmbed)]
#[folder = "lua/"]
struct LuaSrc;

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

    // 3b) decision brain (Faz 2) — resolve & expose llm_complete(system,user,max?)
    // If no model resolves (or the feature is off), the global is absent and the
    // Lua reasoner falls back to rule-based reasoning.
    #[cfg(feature = "llm")]
    {
        if let Some(brain) = llm::Brain::resolve(&home, 2048) {
            let f = lua.create_function(
                move |_, (system, user, max_tokens): (String, String, Option<usize>)| {
                    match brain.complete(&system, &user, max_tokens.unwrap_or(192)) {
                        Ok(s) => Ok(Some(s)),
                        Err(e) => {
                            eprintln!("llm_complete error: {e}");
                            Ok(None)
                        }
                    }
                },
            )?;
            globals.set("llm_complete", f)?;
            globals.set("EVOLUA_HAS_LLM", true)?;
        }
    }

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

    // 4) register every embedded module into package.preload, except main.lua
    let package: Table = globals.get("package")?;
    let preload: Table = package.get("preload")?;
    let mut main_body: Option<Vec<u8>> = None;
    for path in LuaSrc::iter() {
        let p = path.as_ref();
        if !p.ends_with(".lua") {
            continue;
        }
        let file = LuaSrc::get(p).expect("embedded file");
        if p == "main.lua" {
            main_body = Some(file.data.into_owned());
            continue;
        }
        let chunk_name = format!("@{}", p);
        let func = lua
            .load(&*file.data)
            .set_name(&chunk_name)
            .into_function()?;
        preload.set(module_name(p), func)?;
    }

    // 5) breathe life into it
    let mut body = main_body.ok_or_else(|| mlua::Error::RuntimeError("embedded main.lua missing".into()))?;
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
