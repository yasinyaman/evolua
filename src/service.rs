// src/service.rs — a decision brain served by a local LLM server (feature `service`).
//
// If the user already runs Ollama, LM Studio, llama-server or any other
// OpenAI-compatible server, its models are brains EvoLua can think with — the
// server owns the weights, the GPU and the loading. This module finds running
// servers (localhost only, unless more URLs are given) and talks to them over
// plain HTTP. It never starts a server.
#![cfg(feature = "service")]

use std::time::Duration;

use serde_json::{json, Value};

/// Where local servers listen by default.
const DEFAULT_URLS: &[&str] = &[
    "http://127.0.0.1:11434", // Ollama
    "http://127.0.0.1:1234",  // LM Studio
    "http://127.0.0.1:8080",  // llama.cpp llama-server
];

pub struct ServiceModel {
    pub name: String,
    pub size: Option<u64>,
    pub params_b: Option<f64>,
}

pub struct Service {
    pub url: String,
    pub api: &'static str, // "ollama" (native API) | "openai" (/v1)
    pub models: Vec<ServiceModel>,
}

fn agent(read: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_millis(300))
        .timeout_read(read)
        .build()
}

fn get_json(agent: &ureq::Agent, url: &str) -> Option<Value> {
    let body = agent.get(url).call().ok()?.into_string().ok()?;
    serde_json::from_str(&body).ok()
}

/// Embedding-only models can't fill the decision schema.
fn is_embedder(name: &str, family: Option<&str>) -> bool {
    name.to_ascii_lowercase().contains("embed") || matches!(family, Some("bert" | "nomic-bert" | "jina-bert-v2"))
}

/// What a server at `url` offers: Ollama's /api/tags first (it has sizes),
/// else an OpenAI-compatible /v1/models. None if nothing answers.
pub fn probe(url: &str) -> Option<Service> {
    let url = url.trim_end_matches('/').to_string();
    let a = agent(Duration::from_secs(2));
    if let Some(tags) = get_json(&a, &format!("{url}/api/tags")) {
        if let Some(list) = tags["models"].as_array() {
            let models = list
                .iter()
                .filter_map(|m| {
                    let name = m["name"].as_str()?.to_string();
                    let family = m["details"]["family"].as_str();
                    if is_embedder(&name, family) {
                        return None;
                    }
                    let params_b = m["details"]["parameter_size"]
                        .as_str()
                        .and_then(crate::discover::parse_size_label)
                        .or_else(|| crate::discover::size_from_name(&name));
                    Some(ServiceModel { size: m["size"].as_u64(), params_b, name })
                })
                .collect();
            return Some(Service { url, api: "ollama", models });
        }
    }
    let list = get_json(&a, &format!("{url}/v1/models"))?;
    let models = list["data"]
        .as_array()?
        .iter()
        .filter_map(|m| {
            let name = m["id"].as_str()?.to_string();
            if is_embedder(&name, None) {
                return None;
            }
            // llama-server reports its model's parameter count and size in `meta`
            let params_b = m["meta"]["n_params"]
                .as_f64()
                .map(|n| n / 1e9)
                .or_else(|| crate::discover::size_from_name(&name));
            Some(ServiceModel { size: m["meta"]["size"].as_u64(), params_b, name })
        })
        .collect();
    Some(Service { url, api: "openai", models })
}

/// Every running server among the default local URLs, $EVOLUA_SERVICE_URLS
/// (comma/space separated) and `extra`.
pub fn detect(extra: &[String]) -> Vec<Service> {
    let mut urls: Vec<String> = DEFAULT_URLS.iter().map(|s| s.to_string()).collect();
    if let Ok(v) = std::env::var("EVOLUA_SERVICE_URLS") {
        urls.extend(v.split([',', ' ']).filter(|s| !s.is_empty()).map(str::to_string));
    }
    urls.extend(extra.iter().cloned());
    let mut seen = std::collections::HashSet::new();
    urls.retain(|u| seen.insert(u.trim_end_matches('/').to_string()));
    urls.iter().filter_map(|u| probe(u)).collect()
}

/// A model on a running server, ready to answer.
pub struct Client {
    url: String,
    api: String,
    model: String,
    agent: ureq::Agent,
}

impl Client {
    /// Connect to `model` on the server at `url`; fails unless the server is up
    /// and offers that model.
    pub fn connect(url: &str, api: &str, model: &str) -> anyhow::Result<Client> {
        let svc = probe(url).ok_or_else(|| anyhow::anyhow!("no LLM server answering at {url}"))?;
        if !svc.models.iter().any(|m| m.name == model) {
            anyhow::bail!("{url} doesn't offer model '{model}'");
        }
        Ok(Client {
            url: svc.url,
            api: api.to_string(),
            model: model.to_string(),
            // the first answer may wait for the server to load the model
            agent: agent(Duration::from_secs(180)),
        })
    }

    pub fn complete(&self, system: &str, user: &str, max_tokens: usize) -> anyhow::Result<String> {
        let messages = json!([
            { "role": "system", "content": system },
            { "role": "user", "content": user },
        ]);
        let (path, body) = if self.api == "ollama" {
            ("/api/chat", json!({
                "model": self.model, "messages": messages, "stream": false,
                "options": { "temperature": 0.2, "num_predict": max_tokens },
            }))
        } else {
            ("/v1/chat/completions", json!({
                "model": self.model, "messages": messages, "stream": false,
                "temperature": 0.2, "max_tokens": max_tokens,
            }))
        };
        let reply = self
            .agent
            .post(&format!("{}{path}", self.url))
            .set("Content-Type", "application/json")
            .send_string(&body.to_string())?
            .into_string()?;
        let v: Value = serde_json::from_str(&reply)?;
        let text = if self.api == "ollama" {
            v["message"]["content"].as_str()
        } else {
            v["choices"][0]["message"]["content"].as_str()
        };
        text.map(str::to_string).ok_or_else(|| anyhow::anyhow!("unexpected reply from {}", self.url))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpListener;

    /// A one-thread fake server: answers each request by path with canned JSON,
    /// and records the bodies it was sent.
    fn serve(routes: Vec<(&'static str, String)>) -> (String, std::sync::mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let mut r = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                if r.read_line(&mut line).is_err() {
                    continue;
                }
                let path = line.split_whitespace().nth(1).unwrap_or("").to_string();
                let mut len = 0;
                loop {
                    let mut h = String::new();
                    if r.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" {
                        break;
                    }
                    if let Some(v) = h.to_ascii_lowercase().strip_prefix("content-length:") {
                        len = v.trim().parse().unwrap_or(0);
                    }
                }
                let mut body = vec![0; len];
                let _ = r.read_exact(&mut body);
                let _ = tx.send(String::from_utf8_lossy(&body).into_owned());
                let (status, out) = match routes.iter().find(|(p, _)| *p == path) {
                    Some((_, b)) => ("200 OK", b.clone()),
                    None => ("404 Not Found", "{}".to_string()),
                };
                let mut s = stream;
                let _ = write!(s, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{out}", out.len());
            }
        });
        (url, rx)
    }

    #[test]
    fn ollama_tags_list_chat_models_with_sizes() {
        let tags = r#"{"models":[
            {"name":"qwen2.5-coder:1.5b","size":986000000,"details":{"family":"qwen2","parameter_size":"1.5B"}},
            {"name":"nomic-embed-text:latest","size":274000000,"details":{"family":"nomic-bert","parameter_size":"137M"}}]}"#;
        let (url, _) = serve(vec![("/api/tags", tags.into())]);
        let s = probe(&url).unwrap();
        assert_eq!(s.api, "ollama");
        assert_eq!(s.models.len(), 1, "the embedder is left out");
        assert_eq!(s.models[0].name, "qwen2.5-coder:1.5b");
        assert_eq!(s.models[0].params_b, Some(1.5));
    }

    #[test]
    fn openai_servers_are_found_through_v1_models() {
        let models = r#"{"data":[{"id":"qwen2.5-0.5b-instruct","meta":{"n_params":494032768,"size":491400032}},
                                 {"id":"text-embedding-nomic-embed-text-v1.5"}]}"#;
        let (url, _) = serve(vec![("/v1/models", models.into())]);
        let s = probe(&url).unwrap();
        assert_eq!(s.api, "openai");
        assert_eq!(s.models.len(), 1);
        assert!((s.models[0].params_b.unwrap() - 0.494).abs() < 0.001);
    }

    #[test]
    fn nothing_listening_means_no_service() {
        let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port(); // freed again
        assert!(probe(&format!("http://127.0.0.1:{port}")).is_none());
    }

    #[test]
    fn ollama_chat_round_trip() {
        let tags = r#"{"models":[{"name":"m:1b","size":1,"details":{}}]}"#;
        let chat = r#"{"message":{"role":"assistant","content":"SALIENCE: high"}}"#;
        let (url, sent) = serve(vec![("/api/tags", tags.into()), ("/api/chat", chat.into())]);
        let c = Client::connect(&url, "ollama", "m:1b").unwrap();
        assert_eq!(c.complete("sys", "user", 64).unwrap(), "SALIENCE: high");
        let body: Value = serde_json::from_str(&sent.iter().find(|b| b.contains("messages")).unwrap()).unwrap();
        assert_eq!(body["model"], "m:1b");
        assert_eq!(body["options"]["num_predict"], 64);
        assert_eq!(body["messages"][0]["role"], "system");
    }

    #[test]
    fn openai_chat_round_trip_and_unknown_models() {
        let models = r#"{"data":[{"id":"local"}]}"#;
        let chat = r#"{"choices":[{"message":{"role":"assistant","content":"ROUTE: rule"}}]}"#;
        let (url, _) = serve(vec![("/v1/models", models.into()), ("/v1/chat/completions", chat.into())]);
        assert!(Client::connect(&url, "openai", "other").is_err(), "a model the server doesn't offer");
        let c = Client::connect(&url, "openai", "local").unwrap();
        assert_eq!(c.complete("s", "u", 16).unwrap(), "ROUTE: rule");
    }
}
