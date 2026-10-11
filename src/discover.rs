// src/discover.rs — find decision brains that are already on this machine.
//
// Many hosts already hold a usable GGUF: Ollama keeps its models as plain GGUF
// blobs, LM Studio / Jan / GPT4All keep .gguf files, the Hugging Face and
// llama.cpp caches hold whatever was downloaded before. Using one of those is
// free (no network, no 500 MB fetch). This module only FINDS and DESCRIBES
// them — reading each file's GGUF header for architecture, size and quant —
// and never loads anything; which one to use is a Lua policy (core/brain.lua).

use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

/// Directory entries one root may visit while scanning (a cache dir can be big).
const MAX_VISIT: usize = 20_000;
/// How deep below a root .gguf files are looked for.
const MAX_DEPTH: usize = 6;

/// What the GGUF header says about a model (all optional: headers vary).
#[derive(Debug, Default, Clone)]
pub struct Meta {
    pub arch: Option<String>,
    pub name: Option<String>,
    pub size_label: Option<String>,
    pub file_type: Option<u32>,
    pub context_length: Option<u64>,
    pub kind: Option<String>, // general.type: "model" | "adapter" | …
}

#[derive(Debug, Clone)]
pub struct Model {
    pub path: PathBuf,
    pub source: &'static str,
    pub name: String,
    pub size: u64,
    pub meta: Meta,
    /// parameter count from a source that knows better than the header (Ollama's config)
    pub params_hint: Option<String>,
}

impl Model {
    /// Billions of parameters: a size label if there is one ("1.5B", "135M",
    /// "8x7B") — from Ollama's config, the header, or the model / file name —
    /// else an estimate from file size and quantization.
    pub fn params_b(&self) -> f64 {
        let file = self.path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        self.params_hint
            .as_deref()
            .and_then(parse_size_label)
            .or_else(|| self.meta.size_label.as_deref().and_then(parse_size_label))
            .or_else(|| self.meta.name.as_deref().and_then(size_from_name))
            .or_else(|| size_from_name(&file))
            .unwrap_or_else(|| self.size as f64 * 8.0 / bits_per_weight(self.meta.file_type) / 1e9)
    }

    pub fn quant(&self) -> &'static str {
        quant_name(self.meta.file_type)
    }
}

// ── GGUF header ────────────────────────────────────────────────────────────

/// Read the key/value header of a GGUF file (v2/v3). Tensor data is never read.
pub fn read_meta(path: &Path) -> io::Result<Meta> {
    let mut r = BufReader::new(File::open(path)?);
    let mut magic = [0u8; 4];
    r.read_exact(&mut magic)?;
    if &magic != b"GGUF" {
        return Err(bad("not a GGUF file"));
    }
    let version = read_u32(&mut r)?;
    if !(2..=3).contains(&version) {
        return Err(bad("unsupported GGUF version"));
    }
    let _tensors = read_u64(&mut r)?;
    let kv_count = read_u64(&mut r)?;
    if kv_count > 100_000 {
        return Err(bad("implausible GGUF key count"));
    }
    let mut m = Meta::default();
    for _ in 0..kv_count {
        let key = read_string(&mut r)?;
        let ty = read_u32(&mut r)?;
        let wanted = key == "general.architecture"
            || key == "general.name"
            || key == "general.size_label"
            || key == "general.file_type"
            || key == "general.type"
            || key.ends_with(".context_length");
        if !wanted {
            skip_value(&mut r, ty)?;
            continue;
        }
        match (key.as_str(), ty) {
            ("general.architecture", 8) => m.arch = Some(read_string(&mut r)?),
            ("general.name", 8) => m.name = Some(read_string(&mut r)?),
            ("general.size_label", 8) => m.size_label = Some(read_string(&mut r)?),
            ("general.type", 8) => m.kind = Some(read_string(&mut r)?),
            ("general.file_type", _) => m.file_type = read_int(&mut r, ty)?.map(|v| v as u32),
            (_, _) if key.ends_with(".context_length") => m.context_length = read_int(&mut r, ty)?,
            _ => skip_value(&mut r, ty)?,
        }
    }
    Ok(m)
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

fn read_u32(r: &mut impl Read) -> io::Result<u32> {
    let mut b = [0u8; 4];
    r.read_exact(&mut b)?;
    Ok(u32::from_le_bytes(b))
}

fn read_u64(r: &mut impl Read) -> io::Result<u64> {
    let mut b = [0u8; 8];
    r.read_exact(&mut b)?;
    Ok(u64::from_le_bytes(b))
}

fn read_string(r: &mut impl Read) -> io::Result<String> {
    let n = read_u64(r)?;
    if n > 1 << 24 {
        return Err(bad("implausible GGUF string length"));
    }
    let mut b = vec![0u8; n as usize];
    r.read_exact(&mut b)?;
    Ok(String::from_utf8_lossy(&b).into_owned())
}

/// An integer value of any GGUF integer type (None for other types, skipped).
fn read_int<R: Read + Seek>(r: &mut R, ty: u32) -> io::Result<Option<u64>> {
    let v = match ty {
        0 | 1 => {
            let mut b = [0u8; 1];
            r.read_exact(&mut b)?;
            b[0] as u64
        }
        2 | 3 => {
            let mut b = [0u8; 2];
            r.read_exact(&mut b)?;
            u16::from_le_bytes(b) as u64
        }
        4 | 5 => read_u32(r)? as u64,
        10 | 11 => read_u64(r)?,
        _ => {
            skip_value(r, ty)?;
            return Ok(None);
        }
    };
    Ok(Some(v))
}

/// Byte size of a fixed-width GGUF value type (None for string / array).
fn fixed_size(ty: u32) -> Option<i64> {
    match ty {
        0 | 1 | 7 => Some(1),
        2 | 3 => Some(2),
        4..=6 => Some(4),
        10..=12 => Some(8),
        _ => None,
    }
}

fn skip_value<R: Read + Seek>(r: &mut R, ty: u32) -> io::Result<()> {
    if let Some(n) = fixed_size(ty) {
        r.seek(SeekFrom::Current(n))?;
        return Ok(());
    }
    match ty {
        8 => {
            let n = read_u64(r)?;
            r.seek(SeekFrom::Current(n as i64))?;
        }
        9 => {
            let elem = read_u32(r)?;
            let count = read_u64(r)?;
            if let Some(n) = fixed_size(elem) {
                r.seek(SeekFrom::Current(n * count as i64))?;
            } else {
                for _ in 0..count {
                    skip_value(r, elem)?; // arrays of strings (e.g. the tokenizer vocabulary)
                }
            }
        }
        _ => return Err(bad("unknown GGUF value type")),
    }
    Ok(())
}

// ── sizes & quantization ───────────────────────────────────────────────────

/// "1.5B" → 1.5, "135M" → 0.135, "8x7B" → 56, "3.8b" → 3.8; None if unparseable.
pub fn parse_size_label(s: &str) -> Option<f64> {
    let s = s.trim().to_ascii_lowercase();
    let (mult, rest) = match s.split_once('x') {
        Some((n, r)) => (n.parse::<f64>().ok()?, r),
        None => (1.0, s.as_str()),
    };
    let unit = rest.chars().last()?;
    let num: f64 = rest[..rest.len() - 1].parse().ok()?;
    let scale = match unit {
        'b' => 1.0,
        'm' => 1e-3,
        'k' => 1e-6,
        't' => 1e3,
        _ => return None,
    };
    Some(mult * num * scale)
}

/// Pull a size like "1.5b" / "135m" out of a model name ("qwen2.5-coder:1.5b").
pub fn size_from_name(name: &str) -> Option<f64> {
    let lower = name.to_ascii_lowercase();
    let bytes = lower.as_bytes();
    let mut best = None;
    for (i, &c) in bytes.iter().enumerate() {
        if (c == b'b' || c == b'm') && i > 0 && bytes[i - 1].is_ascii_digit() {
            let after_ok = i + 1 == bytes.len() || !bytes[i + 1].is_ascii_alphanumeric();
            let mut j = i;
            while j > 0 && (bytes[j - 1].is_ascii_digit() || bytes[j - 1] == b'.') {
                j -= 1;
            }
            let before_ok = j == 0 || !bytes[j - 1].is_ascii_alphanumeric() || bytes[j - 1] == b'x';
            if after_ok && before_ok {
                best = parse_size_label(&lower[j..=i]);
            }
        }
    }
    best
}

pub fn quant_name(ft: Option<u32>) -> &'static str {
    match ft {
        Some(0) => "F32",
        Some(1) => "F16",
        Some(2) => "Q4_0",
        Some(3) => "Q4_1",
        Some(7) => "Q8_0",
        Some(8) => "Q5_0",
        Some(9) => "Q5_1",
        Some(10) => "Q2_K",
        Some(11) => "Q3_K_S",
        Some(12) => "Q3_K_M",
        Some(13) => "Q3_K_L",
        Some(14) => "Q4_K_S",
        Some(15) => "Q4_K_M",
        Some(16) => "Q5_K_S",
        Some(17) => "Q5_K_M",
        Some(18) => "Q6_K",
        Some(19..=24) | Some(26..=29) | Some(31) => "IQ",
        Some(25) | Some(30) => "IQ4",
        Some(32) => "BF16",
        _ => "?",
    }
}

fn bits_per_weight(ft: Option<u32>) -> f64 {
    match ft {
        Some(0) => 32.0,
        Some(1) | Some(32) => 16.0,
        Some(7) => 8.5,
        Some(18) => 6.6,
        Some(8) | Some(9) | Some(16) | Some(17) => 5.6,
        Some(3) => 5.0,
        Some(2) | Some(14) | Some(15) | Some(25) | Some(30) => 4.8,
        Some(11..=13) => 3.9,
        Some(10) => 3.4,
        Some(19..=24) | Some(26..=29) | Some(31) => 2.8,
        _ => 5.0,
    }
}

// ── is this file a usable decision brain? ──────────────────────────────────

/// Architectures that are GGUF but can't generate text (embedders, encoders,
/// vision projectors).
const NOT_GENERATIVE: &[&str] = &[
    "bert", "nomic-bert", "nomic-bert-moe", "jina-bert-v2", "t5encoder", "clip", "wavtokenizer-dec",
];

fn usable(path: &Path, m: &Meta) -> bool {
    let file = path.file_name().map(|f| f.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
    if file.contains("mmproj") {
        return false;
    }
    // split models load from their first shard only
    if let Some(i) = file.find("-of-") {
        let shard = &file[..i];
        if !shard.ends_with("00001") {
            return false;
        }
    }
    match (&m.arch, &m.kind) {
        (None, _) => false,
        (_, Some(k)) if k == "adapter" => false,
        (Some(a), _) => !NOT_GENERATIVE.contains(&a.as_str()),
    }
}

// ── where models live ──────────────────────────────────────────────────────

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).map(PathBuf::from)
}

fn env_path(key: &str) -> Option<PathBuf> {
    std::env::var_os(key).filter(|v| !v.is_empty()).map(PathBuf::from)
}

/// (source, directory) pairs to look for .gguf files in, for this OS.
fn known_dirs() -> Vec<(&'static str, PathBuf)> {
    let mut v = Vec::new();
    let h = home();
    let local_app = env_path("LOCALAPPDATA");
    if let Some(h) = &h {
        v.push(("lmstudio", h.join(".lmstudio/models")));
        v.push(("lmstudio", h.join(".cache/lm-studio/models")));
        v.push(("jan", h.join("jan/models")));
    }
    let hf = env_path("HF_HUB_CACHE")
        .or_else(|| env_path("HF_HOME").map(|p| p.join("hub")))
        .or_else(|| h.as_ref().map(|h| h.join(".cache/huggingface/hub")));
    if let Some(p) = hf {
        v.push(("huggingface", p));
    }
    if let Some(p) = env_path("LLAMA_CACHE") {
        v.push(("llama.cpp", p));
    }
    if cfg!(target_os = "macos") {
        if let Some(h) = &h {
            v.push(("llama.cpp", h.join("Library/Caches/llama.cpp")));
            v.push(("gpt4all", h.join("Library/Application Support/nomic.ai/GPT4All")));
            v.push(("jan", h.join("Library/Application Support/Jan/data/models")));
        }
    } else if cfg!(target_os = "windows") {
        if let Some(l) = &local_app {
            v.push(("llama.cpp", l.join("llama.cpp")));
            v.push(("gpt4all", l.join("nomic.ai/GPT4All")));
        }
    } else {
        let cache = env_path("XDG_CACHE_HOME").or_else(|| h.as_ref().map(|h| h.join(".cache")));
        let data = env_path("XDG_DATA_HOME").or_else(|| h.as_ref().map(|h| h.join(".local/share")));
        if let Some(c) = cache {
            v.push(("llama.cpp", c.join("llama.cpp")));
        }
        if let Some(d) = data {
            v.push(("gpt4all", d.join("nomic.ai/GPT4All")));
        }
    }
    v
}

/// Extra directories from $EVOLUA_MODEL_DIRS (':'-separated; ';' on Windows).
fn env_dirs() -> Vec<PathBuf> {
    std::env::var_os("EVOLUA_MODEL_DIRS")
        .map(|v| std::env::split_paths(&v).filter(|p| !p.as_os_str().is_empty()).collect())
        .unwrap_or_default()
}

/// Every .gguf below `root` (depth-bounded). Directory symlinks are not
/// followed (no loops); file symlinks are (the Hugging Face cache is made of them).
fn gguf_files(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![(root.to_path_buf(), 0usize)];
    let mut visited = 0usize;
    while let Some((dir, depth)) = stack.pop() {
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            visited += 1;
            if visited > MAX_VISIT {
                return out;
            }
            let path = e.path();
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() {
                if depth + 1 < MAX_DEPTH {
                    stack.push((path, depth + 1));
                }
            } else if path.extension().is_some_and(|x| x.eq_ignore_ascii_case("gguf"))
                && fs::metadata(&path).is_ok_and(|m| m.is_file())
            {
                out.push(path);
            }
        }
    }
    out
}

/// Ollama: manifests/<registry>/<namespace>/<model>/<tag> name a model layer
/// (blobs/sha256-<hex>, a plain GGUF) and a config blob with its parameter size.
fn ollama_models() -> Vec<Model> {
    let root = env_path("OLLAMA_MODELS").or_else(|| home().map(|h| h.join(".ollama/models")));
    let Some(root) = root else { return Vec::new() };
    let mut out = Vec::new();
    let manifests = root.join("manifests");
    let blob = |digest: &str| root.join("blobs").join(digest.replace(':', "-"));
    let mut stack = vec![(manifests.clone(), 0usize)];
    while let Some((dir, depth)) = stack.pop() {
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let path = e.path();
            if e.file_type().is_ok_and(|t| t.is_dir()) {
                if depth < 4 {
                    stack.push((path, depth + 1));
                }
                continue;
            }
            let Ok(text) = fs::read_to_string(&path) else { continue };
            let Ok(man) = serde_json::from_str::<serde_json::Value>(&text) else { continue };
            let model_layer = man["layers"].as_array().and_then(|ls| {
                ls.iter().find(|l| l["mediaType"] == "application/vnd.ollama.image.model")
            });
            let Some(digest) = model_layer.and_then(|l| l["digest"].as_str()) else { continue };
            let gguf = blob(digest);
            let Ok(md) = fs::metadata(&gguf) else { continue };
            // name: registry/namespace/model/tag → "model:tag" for the default library
            let rel: Vec<String> = path
                .strip_prefix(&manifests)
                .map(|p| p.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect())
                .unwrap_or_default();
            let name = match rel.as_slice() {
                [reg, ns, model, tag] if reg == "registry.ollama.ai" && ns == "library" => format!("{model}:{tag}"),
                [_, ns, model, tag] => format!("{ns}/{model}:{tag}"),
                _ => continue,
            };
            let params_hint = man["config"]["digest"]
                .as_str()
                .and_then(|d| fs::read_to_string(blob(d)).ok())
                .and_then(|c| serde_json::from_str::<serde_json::Value>(&c).ok())
                .and_then(|c| c["model_type"].as_str().map(str::to_string));
            out.push(Model {
                meta: read_meta(&gguf).unwrap_or_default(),
                path: gguf,
                source: "ollama",
                name,
                size: md.len(),
                params_hint,
            });
        }
    }
    out
}

fn model_at(path: PathBuf, source: &'static str) -> Option<Model> {
    let size = fs::metadata(&path).ok()?.len();
    let meta = read_meta(&path).ok()?;
    let name = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    Some(Model { path, source, name, size, meta, params_hint: None })
}

/// Every usable model found on this host: Ollama, the known app/cache
/// directories, $EVOLUA_MODEL_DIRS and `extra`. Deduplicated by real path.
pub fn scan(extra: &[PathBuf]) -> Vec<Model> {
    let mut found = ollama_models();
    let mut roots = known_dirs();
    roots.extend(env_dirs().into_iter().map(|p| ("dir", p)));
    roots.extend(extra.iter().cloned().map(|p| ("dir", p)));
    for (source, root) in roots {
        for f in gguf_files(&root) {
            if let Some(m) = model_at(f, source) {
                found.push(m);
            }
        }
    }
    let mut seen = HashSet::new();
    found.retain(|m| usable(&m.path, &m.meta) && seen.insert(fs::canonicalize(&m.path).unwrap_or_else(|_| m.path.clone())));
    found.sort_by(|a, b| a.params_b().total_cmp(&b.params_b()));
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// A minimal GGUF v3 header with the given string / u32 keys (no tensors).
    fn gguf(path: &Path, strings: &[(&str, &str)], ints: &[(&str, u32)], vocab: usize) {
        let mut b: Vec<u8> = b"GGUF".to_vec();
        b.extend(3u32.to_le_bytes());
        b.extend(0u64.to_le_bytes());
        let n = strings.len() + ints.len() + usize::from(vocab > 0);
        b.extend((n as u64).to_le_bytes());
        let s = |b: &mut Vec<u8>, v: &str| {
            b.extend((v.len() as u64).to_le_bytes());
            b.extend(v.as_bytes());
        };
        if vocab > 0 {
            // a big string array first, the way real files carry the tokenizer
            s(&mut b, "tokenizer.ggml.tokens");
            b.extend(9u32.to_le_bytes());
            b.extend(8u32.to_le_bytes());
            b.extend((vocab as u64).to_le_bytes());
            for i in 0..vocab {
                s(&mut b, &format!("tok{i}"));
            }
        }
        for (k, v) in strings {
            s(&mut b, k);
            b.extend(8u32.to_le_bytes());
            s(&mut b, v);
        }
        for (k, v) in ints {
            s(&mut b, k);
            b.extend(4u32.to_le_bytes());
            b.extend(v.to_le_bytes());
        }
        File::create(path).unwrap().write_all(&b).unwrap();
    }

    fn scratch(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("evolua-discover-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn reads_the_header_past_a_large_vocabulary() {
        let d = scratch("meta");
        let p = d.join("m.gguf");
        gguf(&p, &[("general.architecture", "qwen2"), ("general.size_label", "1.5B")],
             &[("general.file_type", 15), ("qwen2.context_length", 32768)], 5000);
        let m = read_meta(&p).unwrap();
        assert_eq!(m.arch.as_deref(), Some("qwen2"));
        assert_eq!(m.size_label.as_deref(), Some("1.5B"));
        assert_eq!(m.file_type, Some(15));
        assert_eq!(m.context_length, Some(32768));
        assert_eq!(quant_name(m.file_type), "Q4_K_M");
    }

    #[test]
    fn rejects_files_that_are_not_gguf() {
        let d = scratch("bad");
        let p = d.join("x.gguf");
        fs::write(&p, b"not a model").unwrap();
        assert!(read_meta(&p).is_err());
    }

    #[test]
    fn size_labels_and_names() {
        assert_eq!(parse_size_label("1.5B"), Some(1.5));
        assert_eq!(parse_size_label("135M"), Some(0.135));
        assert_eq!(parse_size_label("8x7B"), Some(56.0));
        assert_eq!(parse_size_label("huge"), None);
        assert_eq!(size_from_name("qwen2.5-coder:1.5b"), Some(1.5));
        assert_eq!(size_from_name("Qwen2.5 0.5B Instruct"), Some(0.5));
        assert_eq!(size_from_name("SmolLM2-135M-Instruct-Q8_0"), Some(0.135));
        assert_eq!(size_from_name("llama3"), None);
    }

    #[test]
    fn only_generative_whole_models_are_usable() {
        let m = |arch: &str, kind: Option<&str>| Meta {
            arch: Some(arch.into()),
            kind: kind.map(str::to_string),
            ..Meta::default()
        };
        assert!(usable(Path::new("a/qwen.gguf"), &m("qwen2", None)));
        assert!(!usable(Path::new("a/embed.gguf"), &m("nomic-bert", None)));
        assert!(!usable(Path::new("a/lora.gguf"), &m("llama", Some("adapter"))));
        assert!(!usable(Path::new("a/mmproj-model-f16.gguf"), &m("clip", None)));
        assert!(usable(Path::new("a/big-00001-of-00003.gguf"), &m("llama", None)));
        assert!(!usable(Path::new("a/big-00002-of-00003.gguf"), &m("llama", None)));
        assert!(!usable(Path::new("a/x.gguf"), &Meta::default()), "no architecture");
    }

    #[test]
    fn scan_finds_extra_dirs_and_skips_junk() {
        let d = scratch("scan");
        fs::create_dir_all(d.join("nested/deeper")).unwrap();
        gguf(&d.join("nested/deeper/tiny-0.5b.gguf"), &[("general.architecture", "qwen2")], &[("general.file_type", 15)], 0);
        gguf(&d.join("embedder.gguf"), &[("general.architecture", "bert")], &[], 0);
        fs::write(d.join("broken.gguf"), b"GGUF").unwrap();
        let found: Vec<Model> = scan(std::slice::from_ref(&d)).into_iter().filter(|m| m.path.starts_with(&d)).collect();
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].name, "tiny-0.5b");
        assert_eq!(found[0].params_b(), 0.5);
    }
}
