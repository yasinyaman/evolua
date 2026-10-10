// src/brain.rs — the decision brain, loadable and swappable at runtime.
//
// WHICH brain to use is Lua policy (core/brain.lua at boot, the model manager
// later); the host only loads what it is told to and routes completions to it.
// A failed load leaves the current brain in place. Backends:
//   gguf / embedded — in-process llama.cpp (feature `llm`; embedded needs `embed_smol`)
//
// Lua API:
//   host_brain_kinds()               -> { "gguf", "embedded", … } compiled into this binary
//   host_brain_load(spec)            -> info | nil, err   spec = {kind=…, path=…, name=…}
//   host_brain_complete(sys, user, max?) -> text | nil
//   host_brain_info()                -> {kind, id, name, params_b}  (kind="none" if unloaded)

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use mlua::{Lua, Table};

/// Context window the decision prompt runs in (schema + snapshot + RAG lines).
#[cfg(feature = "llm")]
const N_CTX: u32 = 2048;

enum Backend {
    #[cfg(feature = "llm")]
    Local(crate::llm::Brain),
}

impl Backend {
    #[allow(unused_variables)]
    fn complete(&self, system: &str, user: &str, max_tokens: usize) -> anyhow::Result<String> {
        match *self {
            #[cfg(feature = "llm")]
            Backend::Local(ref b) => b.complete(system, user, max_tokens),
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
    [(cfg!(feature = "llm"), "gguf"), (cfg!(feature = "embed_smol"), "embedded")]
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
            Ok((Backend::Local(crate::llm::Brain::load(p, N_CTX)?), id, name))
        }
        #[cfg(feature = "embed_smol")]
        "embedded" => {
            let b = crate::llm::Brain::load_embedded(home, N_CTX)?;
            Ok((Backend::Local(b), format!("embedded:{}", crate::llm::EMBEDDED_NAME), crate::llm::EMBEDDED_NAME.into()))
        }
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

pub fn register(lua: &Lua, home: PathBuf) -> mlua::Result<()> {
    let g = lua.globals();
    let slot: Rc<RefCell<Option<Active>>> = Rc::new(RefCell::new(None));

    g.set("host_brain_kinds", lua.create_function(|_, ()| Ok(kinds()))?)?;

    let s = slot.clone();
    g.set(
        "host_brain_info",
        lua.create_function(move |lua, ()| info_table(lua, s.borrow().as_ref()))?,
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
    g.set(
        "host_brain_complete",
        lua.create_function(move |_, (system, user, max_tokens): (String, String, Option<usize>)| {
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
