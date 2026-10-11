//! Remote ("online") decision brain — an OpenAI-compatible chat endpoint or the
//! Anthropic Messages API, selected at runtime from Lua (`llm_remote_set`).
//!
//! Why: on a small host there may be no RAM for a local model at all; a hosted
//! model costs the host nothing but a socket. The Lua side stays identical —
//! `llm_complete(system, user, max_tokens)` — the host just routes it over HTTP
//! first and falls back to the in-process brain (or rules) on any failure.
//! The API key never touches the Lua config file: Lua reads it from an env var
//! the operator names and hands it to the host once.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// POST {base}/chat/completions — OpenAI, OpenRouter, Groq, Ollama, llama-server, vLLM, …
    OpenAi,
    /// POST {base}/messages — Anthropic
    Anthropic,
}

pub struct Remote {
    pub kind: Kind,
    pub base: String,
    pub model: String,
    pub key: Option<String>,
    /// calls still allowed this life (wallet guard); None = unlimited
    pub budget: Option<u64>,
    pub calls: u64,
    /// FAILOVER state: consecutive failures, and a backoff window during which
    /// complete() refuses immediately (so a dead network never stalls the tick loop)
    pub fails: u32,
    pub down_until: Option<std::time::Instant>,
    pub backoff_secs: u64,
    pub last_error: String,
}

pub const FAILS_TO_DOWN: u32 = 3;
pub const BACKOFF_MIN: u64 = 30;
pub const BACKOFF_MAX: u64 = 600;

impl Remote {
    pub fn new(kind: &str, base: &str, model: &str, key: Option<String>, budget: Option<u64>) -> Option<Remote> {
        let kind = match kind {
            "openai" => Kind::OpenAi,
            "anthropic" => Kind::Anthropic,
            _ => return None,
        };
        Some(Remote {
            kind,
            base: base.trim_end_matches('/').to_string(),
            model: model.to_string(),
            key: key.filter(|k| !k.is_empty()),
            budget,
            calls: 0,
            fails: 0,
            down_until: None,
            backoff_secs: BACKOFF_MIN,
            last_error: String::new(),
        })
    }

    pub fn is_down(&self) -> bool {
        matches!(self.down_until, Some(t) if std::time::Instant::now() < t)
    }

    fn note_failure(&mut self, e: &anyhow::Error) {
        self.fails += 1;
        self.last_error = e.to_string().chars().take(160).collect();
        // auth / quota / payment answers are not transient: go down for the long window at once
        // (a tiny probe may still pass while real-sized requests keep failing — don't flap)
        let hard = ["HTTP 401", "HTTP 402", "HTTP 403"].iter().any(|h| self.last_error.starts_with(h));
        let throttled = self.last_error.starts_with("HTTP 429");
        if hard {
            self.down_until = Some(std::time::Instant::now() + std::time::Duration::from_secs(BACKOFF_MAX));
            self.backoff_secs = BACKOFF_MAX;
        } else if throttled || self.fails >= FAILS_TO_DOWN {
            self.down_until = Some(std::time::Instant::now() + std::time::Duration::from_secs(self.backoff_secs));
            self.backoff_secs = (self.backoff_secs * 2).min(BACKOFF_MAX);
        }
    }

    fn note_success(&mut self) {
        self.fails = 0;
        self.down_until = None;
        self.backoff_secs = BACKOFF_MIN;
        self.last_error.clear();
    }

    /// A completion that honours the backoff window; `force` (the recovery probe) ignores it.
    pub fn complete_tracked(&mut self, system: &str, user: &str, max_tokens: usize, force: bool) -> anyhow::Result<String> {
        if !force && self.is_down() {
            anyhow::bail!("backing off ({})", self.last_error);
        }
        match self.complete(system, user, max_tokens) {
            Ok(out) => {
                self.note_success();
                Ok(out)
            }
            Err(e) => {
                self.note_failure(&e);
                Err(e)
            }
        }
    }

    pub fn label(&self) -> String {
        format!("remote:{}@{}", self.model, self.base)
    }

    pub fn exhausted(&self) -> bool {
        matches!(self.budget, Some(b) if self.calls >= b)
    }

    #[cfg(feature = "remote")]
    pub fn complete(&mut self, system: &str, user: &str, max_tokens: usize) -> anyhow::Result<String> {
        use serde_json::{json, Value};
        if self.exhausted() {
            anyhow::bail!("remote call budget exhausted ({} calls)", self.calls);
        }
        self.calls += 1;
        let (url, body) = match self.kind {
            Kind::OpenAi => (
                format!("{}/chat/completions", self.base),
                json!({
                    "model": self.model,
                    "messages": [
                        { "role": "system", "content": system },
                        { "role": "user", "content": user }
                    ],
                    "max_tokens": max_tokens,
                    "temperature": 0.2
                }),
            ),
            Kind::Anthropic => (
                format!("{}/messages", self.base),
                json!({
                    "model": self.model,
                    "system": system,
                    "messages": [ { "role": "user", "content": user } ],
                    "max_tokens": max_tokens,
                    "temperature": 0.2
                }),
            ),
        };
        // a blocked network fails fast; goes through the mesh gateway when one is set
        let agent = crate::netproxy::agent(std::time::Duration::from_secs(5), std::time::Duration::from_secs(90));
        let mut req = agent.post(&url).set("Content-Type", "application/json");
        match self.kind {
            Kind::OpenAi => {
                if let Some(k) = &self.key {
                    req = req.set("Authorization", &format!("Bearer {k}"));
                }
            }
            Kind::Anthropic => {
                if let Some(k) = &self.key {
                    req = req.set("x-api-key", k);
                }
                req = req.set("anthropic-version", "2023-06-01");
            }
        }
        let text = match req.send_string(&body.to_string()) {
            Ok(resp) => resp.into_string()?,
            Err(ureq::Error::Status(code, resp)) => {
                let detail = resp.into_string().unwrap_or_default();
                anyhow::bail!("HTTP {code}: {}", detail.chars().take(300).collect::<String>());
            }
            Err(e) => anyhow::bail!("transport: {e}"),
        };
        let v: Value = serde_json::from_str(&text)?;
        let out = match self.kind {
            Kind::OpenAi => v["choices"][0]["message"]["content"].as_str().map(|s| s.to_string()),
            Kind::Anthropic => v["content"]
                .as_array()
                .and_then(|a| a.iter().find_map(|c| c["text"].as_str().map(|s| s.to_string()))),
        };
        let out = out.ok_or_else(|| anyhow::anyhow!("no text in response: {}", text.chars().take(200).collect::<String>()))?;
        Ok(strip_thinking(&out))
    }

    #[cfg(not(feature = "remote"))]
    pub fn complete(&mut self, _system: &str, _user: &str, _max_tokens: usize) -> anyhow::Result<String> {
        anyhow::bail!("built without the `remote` feature")
    }
}

pub use crate::brain::strip_thinking;
