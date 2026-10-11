// src/host.rs — native helpers the organism uses instead of the shell.
//
// Perception used to shell out for everything (`ls`, `find`, `mkdir -p`), gluing
// paths into command strings: a directory name with a quote in it broke the
// command, every call cost a child process, and the commands differ per OS (BSD
// find has no -printf, Windows has no find at all). These bindings do the same
// work in-process. They are optional: in plain-Lua mode they are absent and
// core/platform.lua falls back to (quoted) shell commands.

use std::collections::{HashSet, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Instant, UNIX_EPOCH};

use mlua::{Lua, Table};

/// Upper bound on directory entries one walk may visit, whatever its depth and
/// limit — a walk rooted at $HOME must not stall the tick loop.
const MAX_VISIT: usize = 50_000;

pub fn register(lua: &Lua) -> mlua::Result<()> {
    let g = lua.globals();

    // host_list_dir(path) -> { name, ... } sorted, or nil if unreadable
    g.set(
        "host_list_dir",
        lua.create_function(|_, path: String| {
            Ok(fs::read_dir(&path).ok().map(|rd| {
                let mut names: Vec<String> = rd
                    .filter_map(|e| e.ok())
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect();
                names.sort();
                names
            }))
        })?,
    )?;

    // host_mkdir(path) -> true if the directory exists afterwards (parents too)
    g.set(
        "host_mkdir",
        lua.create_function(|_, path: String| Ok(fs::create_dir_all(&path).is_ok()))?,
    )?;

    // host_cwd() -> the current working directory, or nil
    g.set(
        "host_cwd",
        lua.create_function(|_, ()| {
            Ok(std::env::current_dir().ok().map(|p| p.to_string_lossy().into_owned()))
        })?,
    )?;

    // host_now_ms() -> monotonic milliseconds since start. Wall-clock, so the bus
    // can charge a reactor for time spent in child processes (find, ps, lsof) —
    // os.clock() counts only this process's own CPU time.
    let start = Instant::now();
    g.set(
        "host_now_ms",
        lua.create_function(move |_, ()| Ok(start.elapsed().as_secs_f64() * 1000.0))?,
    )?;

    // host_sleep_ms(ms) — the tick loop's pause, without spawning `sleep` (which
    // Windows doesn't have: there the loop used to spin at 100% CPU)
    g.set(
        "host_sleep_ms",
        lua.create_function(|_, ms: f64| {
            if ms.is_finite() && ms > 0.0 {
                std::thread::sleep(std::time::Duration::from_secs_f64(ms / 1000.0));
            }
            Ok(())
        })?,
    )?;

    // host_models(extra_dirs?) -> { {path, source, name, size_mb, params_b, arch,
    //   quant, ctx}, … } — decision brains already on this machine (discover.rs).
    // Finds and describes only; nothing is loaded.
    g.set(
        "host_models",
        lua.create_function(|lua, extra: Option<Table>| {
            let mut dirs = Vec::new();
            if let Some(t) = extra {
                for d in t.sequence_values::<String>() {
                    dirs.push(PathBuf::from(d?));
                }
            }
            let out = lua.create_table()?;
            for (i, m) in crate::discover::scan(&dirs).into_iter().enumerate() {
                let t = lua.create_table()?;
                t.set("path", m.path.to_string_lossy().into_owned())?;
                t.set("source", m.source)?;
                t.set("name", m.name.clone())?;
                t.set("size_mb", (m.size as f64 / 1_048_576.0).round())?;
                t.set("params_b", (m.params_b() * 100.0).round() / 100.0)?;
                t.set("arch", m.meta.arch.clone())?;
                t.set("quant", m.quant())?;
                t.set("ctx", m.meta.context_length)?;
                out.set(i + 1, t)?;
            }
            Ok(out)
        })?,
    )?;

    // host_walk(root, {depth, limit, kind="dir"|"file", suffix, prune={names}})
    //   -> { {path=, dir=, mtime=, size=}, ... }   breadth-first, like `find -maxdepth`
    g.set(
        "host_walk",
        lua.create_function(|lua, (root, opts): (String, Option<Table>)| {
            let o = WalkOpts::from_lua(opts)?;
            let out = lua.create_table()?;
            for (i, e) in walk(Path::new(&root), &o).into_iter().enumerate() {
                let t = lua.create_table()?;
                t.set("path", e.path)?;
                t.set("dir", e.dir)?;
                t.set("mtime", e.mtime)?;
                t.set("size", e.size)?;
                out.set(i + 1, t)?;
            }
            Ok(out)
        })?,
    )?;

    Ok(())
}

struct WalkOpts {
    depth: usize,
    limit: usize,
    kind: Option<String>,
    suffix: Option<String>,
    prune: HashSet<String>,
}

impl WalkOpts {
    fn from_lua(t: Option<Table>) -> mlua::Result<Self> {
        let mut o = WalkOpts { depth: 1, limit: 1000, kind: None, suffix: None, prune: HashSet::new() };
        if let Some(t) = t {
            if let Some(d) = t.get::<Option<usize>>("depth")? {
                o.depth = d;
            }
            if let Some(l) = t.get::<Option<usize>>("limit")? {
                o.limit = l;
            }
            o.kind = t.get::<Option<String>>("kind")?;
            o.suffix = t.get::<Option<String>>("suffix")?;
            if let Some(p) = t.get::<Option<Table>>("prune")? {
                for name in p.sequence_values::<String>() {
                    o.prune.insert(name?);
                }
            }
        }
        Ok(o)
    }
}

struct Entry {
    path: String,
    dir: bool,
    mtime: f64,
    size: u64,
}

/// Entries under `root` down to `o.depth` (root's children are depth 1), never
/// following symlinks and never descending into a `prune`d directory name.
fn walk(root: &Path, o: &WalkOpts) -> Vec<Entry> {
    let mut out = Vec::new();
    let mut queue: VecDeque<(PathBuf, usize)> = VecDeque::from([(root.to_path_buf(), 0)]);
    let mut visited = 0usize;
    while let Some((dir, depth)) = queue.pop_front() {
        if depth >= o.depth {
            continue;
        }
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        let mut entries: Vec<_> = rd.filter_map(|e| e.ok()).collect();
        entries.sort_by_key(|e| e.file_name());
        for e in entries {
            visited += 1;
            if visited > MAX_VISIT {
                return out;
            }
            let path = e.path();
            let Ok(md) = fs::symlink_metadata(&path) else { continue };
            if md.file_type().is_symlink() {
                continue;
            }
            let name = e.file_name().to_string_lossy().into_owned();
            let is_dir = md.is_dir();
            if is_dir {
                if o.prune.contains(&name) {
                    continue;
                }
                queue.push_back((path.clone(), depth + 1));
            }
            let kind_ok = match o.kind.as_deref() {
                Some("dir") => is_dir,
                Some("file") => md.is_file(),
                _ => true,
            };
            let suffix_ok = o.suffix.as_deref().is_none_or(|s| name.ends_with(s));
            if kind_ok && suffix_ok {
                let mtime = md
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map_or(0.0, |d| d.as_secs_f64());
                out.push(Entry {
                    path: path.to_string_lossy().into_owned(),
                    dir: is_dir,
                    mtime,
                    size: if is_dir { 0 } else { md.len() },
                });
                if out.len() >= o.limit {
                    return out;
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{walk, WalkOpts};
    use std::collections::HashSet;
    use std::path::{Path, PathBuf};

    fn tree(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("evolua-walk-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for d in ["a/b/c", "target/deep", "it's \"odd\""] {
            std::fs::create_dir_all(root.join(d)).unwrap();
        }
        for f in ["top.log", "a/x.log", "a/b/y.txt", "target/z.log", "it's \"odd\"/q.log"] {
            std::fs::write(root.join(f), b"x").unwrap();
        }
        root
    }

    fn opts(depth: usize, kind: Option<&str>, suffix: Option<&str>, prune: &[&str]) -> WalkOpts {
        WalkOpts {
            depth,
            limit: 1000,
            kind: kind.map(str::to_string),
            suffix: suffix.map(str::to_string),
            prune: prune.iter().map(|s| s.to_string()).collect::<HashSet<_>>(),
        }
    }

    fn rel(root: &Path, o: &WalkOpts) -> Vec<String> {
        let mut v: Vec<String> = walk(root, o)
            .into_iter()
            .map(|e| e.path[root.to_string_lossy().len() + 1..].to_string())
            .collect();
        v.sort();
        v
    }

    #[test]
    fn depth_kind_and_prune_match_find() {
        let r = tree("dirs");
        assert_eq!(rel(&r, &opts(2, Some("dir"), None, &["target"])), ["a", "a/b", "it's \"odd\""]);
        assert_eq!(rel(&r, &opts(1, Some("file"), None, &[])), ["top.log"]);
    }

    #[test]
    fn suffix_filters_files_and_odd_names_are_plain_data() {
        let r = tree("logs");
        assert_eq!(
            rel(&r, &opts(3, Some("file"), Some(".log"), &["target"])),
            ["a/x.log", "it's \"odd\"/q.log", "top.log"]
        );
    }

    #[test]
    fn limit_stops_the_walk() {
        let r = tree("limit");
        let mut o = opts(5, None, None, &[]);
        o.limit = 3;
        assert_eq!(walk(&r, &o).len(), 3);
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_are_not_followed() {
        let r = tree("links");
        std::os::unix::fs::symlink(&r, r.join("a/loop")).unwrap();
        let all = rel(&r, &opts(6, None, None, &[]));
        assert!(all.iter().all(|p| !p.contains("loop")), "{all:?}");
    }

    #[test]
    fn files_carry_size_and_mtime() {
        let r = tree("meta");
        let e = walk(&r, &opts(1, Some("file"), None, &[])).pop().unwrap();
        assert_eq!(e.size, 1);
        assert!(e.mtime > 0.0 && !e.dir);
    }
}
