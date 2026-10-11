// src/brain.rs — the decision brain, loadable and swappable at runtime.
//
// WHICH brain to use is Lua policy (core/brain.lua at boot, the model manager
// later); the host only loads what it is told to and routes completions to it.
// A failed load leaves the current brain in place. Backends:
//   gguf / embedded — in-process llama.cpp (feature `llm`; embedded needs `embed_smol`)
//   service         — a running Ollama / OpenAI-compatible server (feature `service`)
//   apple           — macOS's on-device Foundation model (feature `apple`, macOS 26+)
//
// Lua API:
//   host_brain_kinds()               -> { "gguf", "embedded", … } compiled into this binary
//   host_brain_load(spec)            -> info | nil, err   spec = {kind=…, path=…, name=…}
//   host_brain_complete(sys, user, max?) -> text | nil
//   host_brain_info()                -> {kind, id, name, params_b}  (kind="none" if unloaded)
//   host_services(urls?)             -> { {url, api, models={ {name, size_mb, params_b} }} }  (`service`)
//   host_apple_status()              -> "available" | why not                                  (`apple`)
//   host_remote_set(kind, base, model, key?, budget?) -> bool   attach an ONLINE service      (`remote`)
//   host_remote_clear()                                          detach it
//   host_remote_status()             -> { label, model, base, calls, fails, down, backoff, last_error } | nil
//   host_remote_probe()              -> bool   one forced call past the backoff window (failover recovery)
//
// With an online service attached and not backed off, host_brain_complete goes over
// HTTP first and falls back to the loaded local backend (or nil → rules) on any
// failure; host_brain_info then reports the online brain as the effective one.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use mlua::{Lua, Table};

enum Backend {
    #[cfg(feature = "llm")]
    Local(crate::llm::Brain),
    #[cfg(feature = "service")]
    Service(crate::service::Client),
    #[cfg(all(feature = "apple", target_os = "macos"))]
    Apple(crate::apple::Model),
}

impl Backend {
    #[allow(unused_variables)]
    fn complete(&self, system: &str, user: &str, max_tokens: usize) -> anyhow::Result<String> {
        match *self {
            #[cfg(feature = "llm")]
            Backend::Local(ref b) => b.complete(system, user, max_tokens),
            #[cfg(feature = "service")]
            Backend::Service(ref c) => c.complete(system, user, max_tokens),
            #[cfg(all(feature = "apple", target_os = "macos"))]
            Backend::Apple(ref m) => m.complete(system, user, max_tokens),
        }
    }
}

struct Active {
    backend: Backend,
    kind: String,
    id: String,
    name: String,
    params_b: Option<f64>,
}

/// The backend kinds this binary can load.
fn kinds() -> Vec<&'static str> {
    [
        (cfg!(feature = "llm"), "gguf"),
        (cfg!(feature = "embed_smol"), "embedded"),
        (cfg!(feature = "service"), "service"),
        (cfg!(all(feature = "apple", target_os = "macos")), "apple"),
    ]
        .into_iter()
        .filter_map(|(on, kind)| on.then_some(kind))
        .collect()
}

/// Load the backend a Lua spec describes. Returns (backend, id, display name).
#[allow(unused_variables)]
fn load(spec: &Table, home: &Path) -> anyhow::Result<(Backend, String, String)> {
    let kind: String = spec.get("kind").unwrap_or_default();
    match kind.as_str() {
        #[cfg(feature = "llm")]
        "gguf" => {
            let path: String = spec.get("path").map_err(|_| anyhow::anyhow!("gguf spec needs a path"))?;
            let p = Path::new(&path);
            let id = format!("gguf:{}", std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf()).display());
            let name: Option<String> = spec.get("name").ok().flatten();
            let name = name.unwrap_or_else(|| p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default());
            Ok((Backend::Local(crate::llm::Brain::load(p, crate::llm::default_ctx())?), id, name))
        }
        #[cfg(feature = "embed_smol")]
        "embedded" => {
            let b = crate::llm::Brain::load_embedded(home, crate::llm::default_ctx())?;
            Ok((Backend::Local(b), format!("embedded:{}", crate::llm::EMBEDDED_NAME), crate::llm::EMBEDDED_NAME.into()))
        }
        #[cfg(feature = "service")]
        "service" => {
            let field = |k: &str| spec.get::<Option<String>>(k).ok().flatten();
            let need = |k: &str| field(k).ok_or_else(|| anyhow::anyhow!("service spec needs `{k}`"));
            let (url, model) = (need("url")?, need("model")?);
            let api = field("api");
            let client = crate::service::Client::connect(&url, api.as_deref().unwrap_or("openai"), &model)?;
            Ok((Backend::Service(client), format!("service:{url}#{model}"), model))
        }
        #[cfg(all(feature = "apple", target_os = "macos"))]
        "apple" => Ok((Backend::Apple(crate::apple::Model::open()?), "apple:on-device".into(), "Apple on-device model".into())),
        other => anyhow::bail!("this binary can't load a '{other}' brain (compiled kinds: {:?})", kinds()),
    }
}

fn info_table(lua: &Lua, a: Option<&Active>) -> mlua::Result<Table> {
    let t = lua.create_table()?;
    match a {
        Some(a) => {
            t.set("kind", a.kind.clone())?;
            t.set("id", a.id.clone())?;
            t.set("name", a.name.clone())?;
            t.set("params_b", a.params_b)?;
        }
        None => {
            t.set("kind", "none")?;
            t.set("id", "none")?;
            t.set("name", "rules")?;
        }
    }
    Ok(t)
}

#[cfg(feature = "remote")]
type RemoteSlot = Rc<RefCell<Option<crate::remote::Remote>>>;

#[cfg(feature = "remote")]
fn remote_info(lua: &Lua, rm: &crate::remote::Remote) -> mlua::Result<Table> {
    let t = lua.create_table()?;
    t.set("kind", "remote")?;
    t.set("id", rm.label())?;
    t.set("name", rm.model.clone())?;
    t.set("base", rm.base.clone())?;
    Ok(t)
}

#[cfg(feature = "remote")]
fn register_remote(lua: &Lua, rslot: &RemoteSlot) -> mlua::Result<()> {
    let g = lua.globals();
    let r = rslot.clone();
    g.set(
        "host_remote_set",
        lua.create_function(
            move |_, (kind, base, model, key, budget): (String, String, String, Option<String>, Option<u64>)| {
                match crate::remote::Remote::new(&kind, &base, &model, key, budget) {
                    Some(rm) => {
                        *r.borrow_mut() = Some(rm);
                        Ok(true)
                    }
                    None => Ok(false),
                }
            },
        )?,
    )?;
    let r = rslot.clone();
    g.set("host_remote_clear", lua.create_function(move |_, ()| { *r.borrow_mut() = None; Ok(()) })?)?;
    let r = rslot.clone();
    g.set(
        "host_remote_status",
        lua.create_function(move |lua, ()| {
            let rg = r.borrow();
            let Some(rm) = rg.as_ref() else { return Ok(None) };
            let t = lua.create_table()?;
            t.set("label", rm.label())?;
            t.set("model", rm.model.clone())?;
            t.set("base", rm.base.clone())?;
            t.set("calls", rm.calls)?;
            t.set("fails", rm.fails)?;
            t.set("down", rm.is_down())?;
            t.set("backoff", rm.backoff_secs)?;
            t.set("last_error", rm.last_error.clone())?;
            Ok(Some(t))
        })?,
    )?;
    let r = rslot.clone();
    g.set(
        "host_remote_probe",
        lua.create_function(move |_, ()| {
            let mut rg = r.borrow_mut();
            let Some(rm) = rg.as_mut() else { return Ok(false) };
            // a probe the size of a small real request, so a tier that only serves tiny
            // calls (or answers 402 to anything bigger) is not mistaken for "back"
            Ok(rm
                .complete_tracked(
                    "You answer in one short sentence.",
                    "Name three Unix commands that show system load, comma separated.",
                    48,
                    true,
                )
                .is_ok())
        })?,
    )?;
    Ok(())
}

pub fn register(lua: &Lua, home: PathBuf) -> mlua::Result<()> {
    let g = lua.globals();
    let slot: Rc<RefCell<Option<Active>>> = Rc::new(RefCell::new(None));
    #[cfg(feature = "remote")]
    let rslot: RemoteSlot = Rc::new(RefCell::new(None));
    #[cfg(feature = "remote")]
    register_remote(lua, &rslot)?;

    g.set("host_brain_kinds", lua.create_function(|_, ()| Ok(kinds()))?)?;

    #[cfg(all(feature = "apple", target_os = "macos"))]
    g.set("host_apple_status", lua.create_function(|_, ()| Ok(crate::apple::status()))?)?;

    #[cfg(feature = "service")]
    g.set(
        "host_services",
        lua.create_function(|lua, extra: Option<Table>| {
            let mut urls = Vec::new();
            if let Some(t) = extra {
                for u in t.sequence_values::<String>() {
                    urls.push(u?);
                }
            }
            let out = lua.create_table()?;
            for (i, s) in crate::service::detect(&urls).into_iter().enumerate() {
                let t = lua.create_table()?;
                t.set("url", s.url)?;
                t.set("api", s.api)?;
                let models = lua.create_table()?;
                for (j, m) in s.models.into_iter().enumerate() {
                    let mt = lua.create_table()?;
                    mt.set("name", m.name)?;
                    mt.set("size_mb", m.size.map(|b| (b as f64 / 1_048_576.0).round()))?;
                    mt.set("params_b", m.params_b.map(|p| (p * 100.0).round() / 100.0))?;
                    models.set(j + 1, mt)?;
                }
                t.set("models", models)?;
                out.set(i + 1, t)?;
            }
            Ok(out)
        })?,
    )?;

    let s = slot.clone();
    #[cfg(feature = "remote")]
    let r = rslot.clone();
    g.set(
        "host_brain_info",
        lua.create_function(move |lua, ()| {
            // the EFFECTIVE brain: an online service that is up answers first
            #[cfg(feature = "remote")]
            if let Some(rm) = r.borrow().as_ref() {
                if !rm.is_down() {
                    return remote_info(lua, rm);
                }
            }
            info_table(lua, s.borrow().as_ref())
        })?,
    )?;

    let s = slot.clone();
    g.set(
        "host_brain_load",
        lua.create_function(move |lua, spec: Table| {
            let kind: String = spec.get("kind").unwrap_or_default();
            if kind == "none" {
                *s.borrow_mut() = None; // unload: back to rules
                return Ok((Some(info_table(lua, None)?), None));
            }
            match load(&spec, &home) {
                Ok((backend, id, name)) => {
                    let params_b: Option<f64> = spec.get("params_b").ok().flatten();
                    *s.borrow_mut() = Some(Active { backend, kind, id, name, params_b });
                    Ok((Some(info_table(lua, s.borrow().as_ref())?), None))
                }
                Err(e) => Ok((None, Some(e.to_string()))),
            }
        })?,
    )?;

    let s = slot;
    #[cfg(feature = "remote")]
    let r = rslot;
    g.set(
        "host_brain_complete",
        lua.create_function(move |_, (system, user, max_tokens): (String, String, Option<usize>)| {
            // 1) the online service, unless it is backed off (then it fails instantly,
            //    so a dead network never stalls the tick loop)
            #[cfg(feature = "remote")]
            {
                let mut rg = r.borrow_mut();
                if let Some(rm) = rg.as_mut() {
                    let was_down = rm.is_down();
                    match rm.complete_tracked(&system, &user, max_tokens.unwrap_or(192), false) {
                        Ok(out) => return Ok(Some(out)),
                        Err(e) => {
                            if !was_down {
                                eprintln!("online brain ({}) error: {e}", rm.model);
                            }
                            if rm.exhausted() {
                                eprintln!("online brain: call budget exhausted — detaching it");
                                *rg = None;
                            }
                        }
                    }
                }
            }
            // 2) the loaded local backend
            let guard = s.borrow();
            let Some(a) = guard.as_ref() else { return Ok(None) };
            match a.backend.complete(&system, &user, max_tokens.unwrap_or(192)) {
                Ok(text) => Ok(Some(text)),
                Err(e) => {
                    eprintln!("brain ({}) error: {e}", a.name);
                    Ok(None)
                }
            }
        })?,
    )?;
    Ok(())
}
