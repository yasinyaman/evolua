//! Process-wide outbound HTTP proxy, set from Lua at runtime (`net_proxy_set(url)`).
//! When a node has no internet but a mesh peer advertises a gateway, the model manager
//! points this at `http://<peer>:<port>`; the online brain client and the model downloader
//! then tunnel through that peer. Nothing else in the host touches the network.

use std::sync::Mutex;
use std::time::Duration;

static PROXY: Mutex<Option<String>> = Mutex::new(None);

pub fn set(url: Option<String>) {
    *PROXY.lock().unwrap() = url.filter(|u| !u.is_empty());
}

pub fn get() -> Option<String> {
    PROXY.lock().unwrap().clone()
}

/// A ureq agent honouring the current proxy (if any) with the given timeouts.
#[cfg(any(feature = "remote", feature = "acquire"))]
pub fn agent(connect: Duration, total: Duration) -> ureq::Agent {
    let mut b = ureq::AgentBuilder::new().timeout_connect(connect).timeout(total);
    if let Some(p) = get() {
        if let Ok(px) = ureq::Proxy::new(&p) {
            b = b.proxy(px);
        }
    }
    b.build()
}
