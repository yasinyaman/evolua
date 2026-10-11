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
#[cfg(feature = "llm")]
mod remote;
#[cfg(feature = "acquire")]
mod acquire;
mod supervisor;
mod mesh;
mod netproxy;

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
    // 2b) MESH (opt-in): the nerve that lets organisms on other hosts find this one and
    // exchange colony mail — transport only, the colony organ keeps its file protocol.
    {
        let argv: Vec<String> = env::args().skip(1).collect();
        if let Some(mcfg) = mesh::config_from(&argv, &home) {
            mesh::spawn(home.clone(), mcfg);
        }
    }

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

    // 3b) decision brain (Faz 2) — LATE-BOUND. The bindings always exist when the
    // `llm` feature is compiled in; the brain slot starts empty unless an explicit
    // model resolves ($EVOLUA_MODEL / last activated / embedded). The Lua model
    // manager fills it at runtime via llm_load(path) — with a model it FINDS on the
    // host or one it DOWNLOADS sized to the host. llm_complete returns nil while the
    // slot is empty, so the Lua reasoner falls back to rules (and that fallback rate
    // is exactly the "bottleneck" signal that drives acquisition).
    #[cfg(feature = "llm")]
    {
        use std::cell::RefCell;
        use std::rc::Rc;
        let n_ctx = llm::default_ctx();
        let slot: Rc<RefCell<Option<llm::Brain>>> =
            Rc::new(RefCell::new(llm::Brain::resolve(&home, n_ctx)));

        // ONLINE brain slot: when set, llm_complete goes over HTTP first and falls
        // back to the in-process brain (or nil → rules) on any failure.
        let rslot: Rc<RefCell<Option<remote::Remote>>> = Rc::new(RefCell::new(None));

        let s = slot.clone();
        let r = rslot.clone();
        let complete = lua.create_function(
            move |_, (system, user, max_tokens): (String, String, Option<usize>)| {
                let max = max_tokens.unwrap_or(192);
                {
                    let mut rg = r.borrow_mut();
                    if let Some(rm) = rg.as_mut() {
                        let was_down = rm.is_down();
                        match rm.complete_tracked(&system, &user, max, false) {
                            Ok(out) => return Ok(Some(out)),
                            Err(e) => {
                                if !was_down {
                                    eprintln!("llm_remote error: {e}");
                                }
                                if rm.exhausted() {
                                    eprintln!("llm_remote: budget exhausted — detaching the online brain");
                                    *rg = None;
                                }
                            }
                        }
                    }
                }
                let guard = s.borrow();
                let Some(brain) = guard.as_ref() else { return Ok(None) };
                match brain.complete(&system, &user, max) {
                    Ok(out) => Ok(Some(out)),
                    Err(e) => {
                        eprintln!("llm_complete error: {e}");
                        Ok(None)
                    }
                }
            },
        )?;
        globals.set("llm_complete", complete)?;

        // llm_remote_set(kind, base_url, model, api_key?, budget?) -> bool
        //   kind = "openai" (any OpenAI-compatible endpoint) | "anthropic"
        let r = rslot.clone();
        let rset = lua.create_function(
            move |_, (kind, base, model, key, budget): (String, String, String, Option<String>, Option<u64>)| {
                match remote::Remote::new(&kind, &base, &model, key, budget) {
                    Some(rm) => {
                        *r.borrow_mut() = Some(rm);
                        Ok(true)
                    }
                    None => Ok(false),
                }
            },
        )?;
        globals.set("llm_remote_set", rset)?;

        let r = rslot.clone();
        let rclear = lua.create_function(move |_, ()| {
            *r.borrow_mut() = None;
            Ok(())
        })?;
        globals.set("llm_remote_clear", rclear)?;

        // llm_remote_status() -> table|nil : { label, calls, fails, down, backoff, last_error }
        let r = rslot.clone();
        let rstatus = lua.create_function(move |lua, ()| {
            let rg = r.borrow();
            let Some(rm) = rg.as_ref() else { return Ok(None) };
            let t = lua.create_table()?;
            t.set("label", rm.label())?;
            t.set("calls", rm.calls)?;
            t.set("fails", rm.fails)?;
            t.set("down", rm.is_down())?;
            t.set("backoff", rm.backoff_secs)?;
            t.set("last_error", rm.last_error.clone())?;
            Ok(Some(t))
        })?;
        globals.set("llm_remote_status", rstatus)?;

        // llm_remote_probe() -> bool : one tiny forced call, ignoring the backoff window —
        // the model manager uses it to notice the service is back (FAILOVER recovery).
        let r = rslot.clone();
        let rprobe = lua.create_function(move |_, ()| {
            let mut rg = r.borrow_mut();
            let Some(rm) = rg.as_mut() else { return Ok(false) };
            // a probe the size of a small real request, so a tier that only serves tiny
            // calls (or a 402 on anything bigger) is not mistaken for "back"
            Ok(rm.complete_tracked(
                "You answer in one short sentence.",
                "Name three Unix commands that show system load, comma separated.",
                48,
                true,
            )
            .is_ok())
        })?;
        globals.set("llm_remote_probe", rprobe)?;

        // llm_load(path) -> bool : (re)load the brain from a GGUF on disk; hot-swap.
        let s = slot.clone();
        let load = lua.create_function(move |_, path: String| {
            // the llama backend is a process-wide singleton: the old brain must be
            // dropped (freeing it) BEFORE a new one can initialise, or the load fails
            // with BackendAlreadyInitialized. Keep the old path to roll back on failure.
            let prev = s.borrow_mut().take().map(|b| b.path().to_path_buf());
            match llm::Brain::load(std::path::Path::new(&path), n_ctx) {
                Ok(b) => {
                    *s.borrow_mut() = Some(b);
                    Ok(true)
                }
                Err(e) => {
                    eprintln!("llm_load error: {e}");
                    if let Some(p) = prev {
                        if let Ok(b) = llm::Brain::load(&p, n_ctx) {
                            *s.borrow_mut() = Some(b); // rollback: the previous brain is back
                        }
                    }
                    Ok(false)
                }
            }
        })?;
        globals.set("llm_load", load)?;

        // llm_unload() : drop the brain (free RAM) — e.g. when host capacity drops.
        let s = slot.clone();
        let unload = lua.create_function(move |_, ()| {
            *s.borrow_mut() = None;
            Ok(())
        })?;
        globals.set("llm_unload", unload)?;

        // llm_model() -> label|nil : the active brain — "remote:<model>@<url>" when an
        // online service is attached, else the path of the in-process GGUF.
        let s = slot.clone();
        let r = rslot.clone();
        let which = lua.create_function(move |_, ()| {
            // the EFFECTIVE brain: a backed-off online service does not count — then the
            // local GGUF (if any) is what answers, and the model manager may attach one
            if let Some(rm) = r.borrow().as_ref() {
                if !rm.is_down() {
                    return Ok(Some(rm.label()));
                }
            }
            Ok(s.borrow().as_ref().map(|b| b.path().to_string_lossy().to_string()))
        })?;
        globals.set("llm_model", which)?;

        globals.set("EVOLUA_HAS_LLM", true)?;
        globals.set("EVOLUA_LLM_CTX", n_ctx)?;
    }

    // 3b-bis) outbound proxy (mesh gateway): net_proxy_set(url) / net_proxy_clear() / net_proxy()
    {
        let set = lua.create_function(|_, url: String| {
            netproxy::set(Some(url));
            Ok(())
        })?;
        globals.set("net_proxy_set", set)?;
        let clear = lua.create_function(|_, ()| {
            netproxy::set(None);
            Ok(())
        })?;
        globals.set("net_proxy_clear", clear)?;
        let get = lua.create_function(|_, ()| Ok(netproxy::get()))?;
        globals.set("net_proxy", get)?;
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
