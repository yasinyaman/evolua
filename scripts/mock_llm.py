#!/usr/bin/env python3
"""A mock OpenAI-/Anthropic-compatible chat endpoint on 127.0.0.1:48200 for the online-brain
failover test (CLAUDE.md "Tests & reset"): answers the reasoner with a rules hint and the synth
organ with a canned organ. Run it with `python3 -I scripts/mock_llm.py`, point the organism at it
(`GROQ_API_KEY=x EVOLUA_LLM_BASE=http://127.0.0.1:48200/v1 evolua --llm-api groq …`), kill and
restart it mid-run, and read state/audit.log for `brain_failover`. Check `lsof -i :48200` first:
a mock left over from an earlier session makes the test pass vacuously."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
ORGAN = '''```lua
local NAME = "syn_mock_1"
local last, last_msg = nil, nil
return {
  name = NAME, desc = "load watch (mock-written)", events = { "self.heartbeat" },
  attach = function(ctx)
    ctx.bus:subscribe("self.heartbeat", function(ev)
      local d = ev.data or {}
      if (d.tick or 0) % 10 ~= 0 then return false end
      local p = io.popen("uptime 2>/dev/null"); if not p then return false end
      local line = p:read("*l") or ""; p:close()
      local la = tonumber(line:match("load averages?:%s+([%d%.]+)"))
      if not la then return false end
      if last == nil then last = la; return false end
      if math.abs(la - last) < 0.5 then return false end
      local msg = string.format("load average %.2f -> %.2f", last, la); last = la
      if msg == last_msg then return false end
      last_msg = msg
      ctx.bus:emit("load.change", { to = la }); ctx.report(NAME, msg)
      return { handled = true }
    end, NAME)
  end,
}
```'''
BUGGY = ORGAN.replace('local la = tonumber(line:match("load averages?:%s+([%d%.]+)"))', 'local la = tonumber(line:gsub("x", "y"))').replace("syn_mock_1", "syn_buggy_1")
def reply(system, user):
    if "monitoring goal" in system: return "Observe the 1-minute load average from `uptime` or `iostat -c 1`; report jumps above 0.5."
    if "organs" in system and "garip" in user and "ran but threw" not in user: return BUGGY
    if "organs" in system: return ORGAN
    return "rules please"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = json.loads(self.rfile.read(n) or b"{}")
        auth = self.headers.get("Authorization") or self.headers.get("x-api-key") or "-"
        sys.stderr.write(f"[mock] {self.path} model={body.get('model')} auth={auth[:12]} ver={self.headers.get('anthropic-version')}\n")
        if self.path.endswith("/chat/completions"):
            msgs = body.get("messages", []); system = next((m["content"] for m in msgs if m["role"]=="system"), ""); user = next((m["content"] for m in msgs if m["role"]=="user"), "")
            out = {"choices": [{"message": {"role": "assistant", "content": reply(system, user)}}]}
        elif self.path.endswith("/messages"):
            system = body.get("system", ""); user = body["messages"][0]["content"]
            out = {"content": [{"type": "text", "text": reply(system, user)}]}
        else:
            self.send_response(404); self.end_headers(); return
        data = json.dumps(out).encode(); self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
HTTPServer(("127.0.0.1", 48200), H).serve_forever()
