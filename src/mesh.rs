//! Host-side MESH — lets organisms on DIFFERENT machines find each other and talk.
//!
//! The colony organ (Lua) already speaks a file protocol inside one data home:
//! presence beacons in `colony/peers/<id>`, mail in `colony/inbox/<id>/*.msg`.
//! This thread is a nerve that extends that file dance across hosts, so the
//! organ needs no change and still sees remote peers as plain files:
//!
//!   * DISCOVERY — a UDP broadcast beacon on the LAN every few seconds, plus the
//!     same beacon over TCP to static seeds (`--mesh-seed host:port`) for links
//!     that broadcast cannot cross (Tailscale, VPN, WAN). A received beacon is
//!     written as `colony/peers/<id>` with an extra `addr=ip:port` field.
//!   * MESSAGES — the organ writes mail for a peer into `colony/inbox/<peer>/`.
//!     If that peer's beacon carries `addr=`, the file is remote: we ship it over
//!     TCP and delete it; the receiving nerve drops it into its own inbox dir.
//!
//! Like `supervisor.rs` this sits BELOW evolution: transport, not behaviour.
//! Opt-in (`--mesh` / `EVOLUA_MESH=1`). Open by design (see project notes);
//! `EVOLUA_MESH_TOKEN` adds a shared-secret check when the operator wants one.

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream, ToSocketAddrs, UdpSocket};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAGIC: &str = "EVOLUA1";

pub struct Config {
    pub port: u16,
    pub seeds: Vec<String>,
    pub colony_root: PathBuf,
    pub token: Option<String>,
    pub beacon_secs: u64,
    /// serve as an internet GATEWAY for peers: a plain HTTP CONNECT proxy on port+1
    pub gateway: bool,
}

/// Parse `--mesh*` / `--colony-root` from argv plus `EVOLUA_MESH*` env. None = mesh off.
pub fn config_from(args: &[String], home: &Path) -> Option<Config> {
    let env = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
    let mut on = env("EVOLUA_MESH").map(|v| v != "0").unwrap_or(false);
    let mut port: u16 = env("EVOLUA_MESH_PORT").and_then(|v| v.parse().ok()).unwrap_or(7707);
    let mut seeds: Vec<String> = env("EVOLUA_MESH_SEEDS")
        .map(|v| v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect())
        .unwrap_or_default();
    let mut colony_root = home.to_path_buf();
    let mut gateway = env("EVOLUA_MESH_GATEWAY").map(|v| v != "0").unwrap_or(false);
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--mesh" => on = true,
            "--no-mesh" => on = false,
            "--mesh-gateway" => {
                on = true;
                gateway = true;
            }
            "--mesh-port" => {
                if let Some(v) = args.get(i + 1) {
                    port = v.parse().unwrap_or(port);
                    i += 1;
                }
            }
            "--mesh-seed" => {
                if let Some(v) = args.get(i + 1) {
                    seeds.push(v.clone());
                    on = true;
                    i += 1;
                }
            }
            "--colony-root" => {
                if let Some(v) = args.get(i + 1) {
                    colony_root = PathBuf::from(v);
                    i += 1;
                }
            }
            _ => {}
        }
        i += 1;
    }
    if !on {
        return None;
    }
    Some(Config {
        port,
        seeds,
        colony_root,
        token: env("EVOLUA_MESH_TOKEN"),
        beacon_secs: env("EVOLUA_MESH_BEACON_SECS").and_then(|v| v.parse().ok()).unwrap_or(3).max(1),
        gateway,
    })
}

pub fn spawn(home: PathBuf, cfg: Config) {
    thread::spawn(move || run(home, cfg));
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn append(path: &Path, line: &str) {
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{} {}", now(), line);
    }
}

fn hostname() -> String {
    std::process::Command::new("hostname")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "host".to_string())
}

/// `state/mesh_id` is written by main.lua once the colony id is known.
fn wait_for_id(home: &Path, log: &Path) -> (String, String) {
    let p = home.join("state").join("mesh_id");
    let started = Instant::now();
    loop {
        if let Ok(s) = fs::read_to_string(&p) {
            let id = s.lines().find_map(|l| l.strip_prefix("id=")).unwrap_or("").trim().to_string();
            let gen = s.lines().find_map(|l| l.strip_prefix("gen=")).unwrap_or("0").trim().to_string();
            if !id.is_empty() {
                return (id, gen);
            }
        }
        if started.elapsed() > Duration::from_secs(60) && started.elapsed().as_secs() % 60 == 0 {
            append(log, "waiting for state/mesh_id (is this a plain-lua run without the colony?)");
        }
        thread::sleep(Duration::from_secs(1));
    }
}

struct Shared {
    me: String,
    peers_dir: PathBuf,
    inbox_dir: PathBuf,
    log: PathBuf,
    token: Option<String>,
    counter: AtomicU64,
    known: Mutex<Vec<(String, SocketAddr)>>, // remote peers we have heard from (for status)
}

impl Shared {
    fn authorised(&self, line: &str) -> bool {
        match &self.token {
            None => true,
            Some(t) => line.split_whitespace().any(|kv| kv == format!("token={t}")),
        }
    }

    /// A beacon line: `EVOLUA1 BEACON id=<id> gen=<g> tcp=<port> host=<name> [token=..]`
    fn on_beacon(&self, line: &str, from_ip: std::net::IpAddr) {
        if !self.authorised(line) {
            return;
        }
        let field = |k: &str| line.split_whitespace().find_map(|kv| kv.strip_prefix(&format!("{k}="))).map(|s| s.to_string());
        let (Some(id), Some(tcp)) = (field("id"), field("tcp").and_then(|p| p.parse::<u16>().ok())) else { return };
        if id == self.me {
            return;
        }
        let gen = field("gen").unwrap_or_else(|| "0".into());
        let host = field("host").unwrap_or_else(|| "?".into());
        let addr = SocketAddr::new(from_ip, tcp);
        let _ = fs::create_dir_all(&self.peers_dir);
        // CAPABILITIES the peer advertises (brain, model endpoint, internet, gateway) travel
        // as extra k=v fields; the model manager reads them from this file
        let extras: Vec<String> = line
            .split_whitespace()
            .filter(|kv| {
                kv.contains('=')
                    && !["id=", "gen=", "tcp=", "host=", "token="].iter().any(|k| kv.starts_with(k))
                    && !kv.starts_with(MAGIC)
            })
            .map(|s| s.to_string())
            .collect();
        // the colony organ reads `time=` for liveness and prunes stale beacons itself
        let body = format!("id={id} gen={gen} tick=0 organs=0 time={} addr={addr} host={host} {}\n", now(), extras.join(" "));
        let _ = fs::write(self.peers_dir.join(&id), body);
        let mut known = self.known.lock().unwrap();
        if let Some(k) = known.iter_mut().find(|(i, _)| *i == id) {
            k.1 = addr;
        } else {
            known.push((id.clone(), addr));
            append(&self.log, &format!("peer discovered: {id} at {addr} ({host})"));
        }
    }

    /// Mail: `EVOLUA1 MSG to=<id> [token=..]` + newline + body (body carries `from=`)
    fn on_msg(&self, head: &str, body: &str) {
        if !self.authorised(head) {
            return;
        }
        let Some(to) = head.split_whitespace().find_map(|kv| kv.strip_prefix("to=")) else { return };
        let from = body.lines().find_map(|l| l.strip_prefix("from=")).unwrap_or("remote").replace('/', "_");
        let dir = self.inbox_dir.join(to);
        let _ = fs::create_dir_all(&dir);
        let n = self.counter.fetch_add(1, Ordering::Relaxed);
        let name = format!("{from}.net{}.{n}.msg", now());
        let _ = fs::write(dir.join(name), body);
    }
}

fn run(home: PathBuf, cfg: Config) {
    let state = home.join("state");
    let _ = fs::create_dir_all(&state);
    let log = state.join("mesh.log");
    let (me, gen) = wait_for_id(&home, &log);
    let colony = cfg.colony_root.join("colony");
    let shared = Arc::new(Shared {
        me: me.clone(),
        peers_dir: colony.join("peers"),
        inbox_dir: colony.join("inbox"),
        log: log.clone(),
        token: cfg.token.clone(),
        counter: AtomicU64::new(0),
        known: Mutex::new(Vec::new()),
    });
    let host = hostname();
    let token_kv = cfg.token.as_ref().map(|t| format!(" token={t}")).unwrap_or_default();
    let gateway_kv = if cfg.gateway { format!(" gateway={}", cfg.port + 1) } else { String::new() };
    let caps_path = state.join("mesh_caps");
    // the beacon is rebuilt every round from state/mesh_caps (brain=, llm_port=, online=, …)
    let make_beacon = |caps_path: &Path| {
        let caps = fs::read_to_string(caps_path)
            .map(|s| {
                s.lines()
                    .filter(|l| l.contains('=') && !l.contains(' '))
                    .map(|l| format!(" {}", l.trim()))
                    .collect::<String>()
            })
            .unwrap_or_default();
        format!("{MAGIC} BEACON id={me} gen={gen} tcp={} host={host}{gateway_kv}{caps}{token_kv}", cfg.port)
    };
    append(&log, &format!("mesh up: id={me} port={} seeds={:?} token={} gateway={}", cfg.port, cfg.seeds, cfg.token.is_some(), cfg.gateway));
    if cfg.gateway {
        spawn_gateway(cfg.port + 1, log.clone());
    }

    // --- TCP receiver -----------------------------------------------------------------
    match TcpListener::bind(("0.0.0.0", cfg.port)) {
        Ok(listener) => {
            let sh = shared.clone();
            thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    let sh = sh.clone();
                    thread::spawn(move || handle_tcp(stream, sh));
                }
            });
        }
        Err(e) => append(&log, &format!("tcp bind {} failed: {e} — messages from remote peers cannot arrive", cfg.port)),
    }

    // --- UDP receiver -----------------------------------------------------------------
    let udp = UdpSocket::bind(("0.0.0.0", cfg.port)).ok();
    if let Some(sock) = &udp {
        let _ = sock.set_broadcast(true);
        let _ = sock.set_read_timeout(Some(Duration::from_millis(500)));
    } else {
        append(&log, &format!("udp bind {} failed — LAN discovery off, seeds only", cfg.port));
    }
    let udp_rx = udp.as_ref().and_then(|s| s.try_clone().ok());
    if let Some(rx) = udp_rx {
        let sh = shared.clone();
        thread::spawn(move || {
            let mut buf = [0u8; 2048];
            loop {
                if let Ok((n, from)) = rx.recv_from(&mut buf) {
                    if let Ok(s) = std::str::from_utf8(&buf[..n]) {
                        let s = s.trim();
                        if s.starts_with(&format!("{MAGIC} BEACON")) {
                            sh.on_beacon(s, from.ip());
                        }
                    }
                }
            }
        });
    }

    // --- beacon + forward loop ------------------------------------------------------------
    let mut last_beacon = Instant::now() - Duration::from_secs(3600);
    loop {
        if last_beacon.elapsed() >= Duration::from_secs(cfg.beacon_secs) {
            last_beacon = Instant::now();
            let beacon = make_beacon(&caps_path);
            if let Some(sock) = &udp {
                let _ = sock.send_to(beacon.as_bytes(), ("255.255.255.255", cfg.port));
            }
            for seed in &cfg.seeds {
                send_line(seed, &beacon, "", &log);
            }
            // also beacon directly to every peer we know (keeps links alive beyond the LAN)
            let known: Vec<(String, SocketAddr)> = shared.known.lock().unwrap().clone();
            for (_, addr) in known {
                send_line(&addr.to_string(), &beacon, "", &log);
            }
        }
        forward_outgoing(&shared, &log);
        thread::sleep(Duration::from_millis(700));
    }
}

fn handle_tcp(mut stream: TcpStream, sh: Arc<Shared>) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let peer_ip = stream.peer_addr().map(|a| a.ip());
    let mut reader = BufReader::new(&mut stream);
    let mut head = String::new();
    if reader.read_line(&mut head).is_err() {
        return;
    }
    let head = head.trim().to_string();
    if head.starts_with(&format!("{MAGIC} BEACON")) {
        if let Ok(ip) = peer_ip {
            sh.on_beacon(&head, ip);
        }
    } else if head.starts_with(&format!("{MAGIC} MSG")) {
        let mut body = String::new();
        let _ = reader.read_to_string(&mut body);
        if body.len() <= 64 * 1024 {
            sh.on_msg(&head, &body);
        }
    }
}

fn send_line(addr: &str, head: &str, body: &str, log: &Path) -> bool {
    let Some(sa) = addr.to_socket_addrs().ok().and_then(|mut it| it.next()) else {
        append(log, &format!("cannot resolve seed {addr}"));
        return false;
    };
    match TcpStream::connect_timeout(&sa, Duration::from_secs(2)) {
        Ok(mut s) => {
            let _ = s.set_write_timeout(Some(Duration::from_secs(3)));
            let _ = s.write_all(head.as_bytes());
            let _ = s.write_all(b"\n");
            if !body.is_empty() {
                let _ = s.write_all(body.as_bytes());
            }
            true
        }
        Err(_) => false,
    }
}

/// Mail the organ wrote for a REMOTE peer (its beacon carries `addr=`) is shipped and removed.
fn forward_outgoing(sh: &Arc<Shared>, log: &Path) {
    let Ok(peers) = fs::read_dir(&sh.peers_dir) else { return };
    for entry in peers.flatten() {
        let id = entry.file_name().to_string_lossy().to_string();
        if id == sh.me {
            continue;
        }
        let Ok(beacon) = fs::read_to_string(entry.path()) else { continue };
        let Some(addr) = beacon.split_whitespace().find_map(|kv| kv.strip_prefix("addr=")) else { continue };
        let Ok(mails) = fs::read_dir(sh.inbox_dir.join(&id)) else { continue };
        for m in mails.flatten() {
            let name = m.file_name().to_string_lossy().to_string();
            if !name.ends_with(".msg") || name.contains(".net") {
                continue; // `.net` marks mail that ARRIVED over the mesh for a local peer sharing this inbox tree
            }
            let Ok(body) = fs::read_to_string(m.path()) else { continue };
            let token_kv = sh.token.as_ref().map(|t| format!(" token={t}")).unwrap_or_default();
            let head = format!("{MAGIC} MSG to={id}{token_kv}");
            if send_line(addr, &head, &body, log) {
                let _ = fs::remove_file(m.path());
            } else {
                append(log, &format!("could not deliver to {id} at {addr} — will retry"));
                break;
            }
        }
    }
}

/// Minimal HTTP CONNECT proxy: a peer without internet tunnels its TLS connections (online
/// brain, model downloads) through this node. Plain `GET http://…` is not supported — every
/// endpoint the organism talks to is HTTPS. Bounded to one thread per connection, 60 s idle.
fn spawn_gateway(port: u16, log: PathBuf) {
    thread::spawn(move || {
        let listener = match TcpListener::bind(("0.0.0.0", port)) {
            Ok(l) => l,
            Err(e) => {
                append(&log, &format!("gateway bind {port} failed: {e}"));
                return;
            }
        };
        append(&log, &format!("gateway (CONNECT proxy) listening on {port}"));
        for client in listener.incoming().flatten() {
            let log = log.clone();
            thread::spawn(move || {
                let _ = client.set_read_timeout(Some(Duration::from_secs(10)));
                let mut reader = BufReader::new(client.try_clone().unwrap());
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    return;
                }
                let mut parts = line.split_whitespace();
                let (Some("CONNECT"), Some(target)) = (parts.next(), parts.next()) else {
                    let mut c = client;
                    let _ = c.write_all(b"HTTP/1.1 405 Method Not Allowed\r\n\r\n");
                    return;
                };
                // drain request headers
                let mut hdr = String::new();
                while reader.read_line(&mut hdr).map(|n| n > 0).unwrap_or(false) && hdr.trim() != "" {
                    hdr.clear();
                }
                let Some(sa) = target.to_socket_addrs().ok().and_then(|mut it| it.next()) else { return };
                let mut client = client;
                match TcpStream::connect_timeout(&sa, Duration::from_secs(8)) {
                    Ok(upstream) => {
                        let _ = client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n");
                        append(&log, &format!("gateway: tunnel to {target}"));
                        let _ = client.set_read_timeout(Some(Duration::from_secs(60)));
                        let _ = upstream.set_read_timeout(Some(Duration::from_secs(60)));
                        let (mut c2, mut u2) = (client.try_clone().unwrap(), upstream.try_clone().unwrap());
                        let t = thread::spawn(move || {
                            let _ = std::io::copy(&mut c2, &mut u2);
                            let _ = u2.shutdown(std::net::Shutdown::Write);
                        });
                        let (mut u3, mut c3) = (upstream, client);
                        let _ = std::io::copy(&mut u3, &mut c3);
                        let _ = c3.shutdown(std::net::Shutdown::Write);
                        let _ = t.join();
                    }
                    Err(e) => {
                        let _ = client.write_all(format!("HTTP/1.1 502 Bad Gateway\r\n\r\n{e}").as_bytes());
                    }
                }
            });
        }
    });
}
