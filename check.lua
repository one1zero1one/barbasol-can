-- Checks for the parsing in harnesses.lua: rex do check.lua
local H = dofile((debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]*$") or ".") .. "/harnesses.lua")

assert(H.utc("1970-01-01T00:00:00.000Z") == 0)
assert(H.utc("2026-11-08T06:35:25.882Z") == 1794119725)
assert(H.utc("2024-02-29T12:00:00Z") == 1709208000) -- leap day
assert(H.utc("not a time") == nil)

assert(H.codex_exec("/bin/codex exec --sandbox read-only hi"))
assert(H.codex_exec("/bin/codex exec"))   -- prompt read from stdin
assert(not H.codex_exec('/bin/codex "exec the test suite"'))
assert(not H.codex_exec("/bin/codex -C /work/exec tools"))
assert(not H.codex_exec("/bin/codex resume 01a0f5d2-d190-7461-9540-3c618e1fea5e"))

-- Claude Code: the process is named after its version; the agent view's title names the session.
assert(H.claude.match{ name = "claude" })
assert(H.claude.match{ name = "2.1.322", argv0 = "/home/me/.local/bin/claude" })
assert(H.claude.match{ name = "2.1.322", argv0 = "claude" })
assert(not H.claude.match{ name = "zsh", argv0 = "-zsh" })
assert(not H.claude.match{ name = "node", argv0 = "/opt/claude-tools/node" })

assert(H.agent_view_session("✳ fix-login") == "fix-login")
assert(H.agent_view_session("◑ two words") == "two words")
assert(H.agent_view_session("plain-name") == "plain-name")
assert(H.agent_view_session("claude agents") == nil)
assert(H.agent_view_session("2 awaiting input · claude agents") == nil)
assert(H.agent_view_session("") == nil)
assert(H.agent_view_session(nil) == nil)

local list = {
  { sessionId = "aaaa", name = "fix-login", cwd = "/work/app" },
  { sessionId = "bbbb", name = "twin", cwd = "/work/a" },
  { sessionId = "cccc", name = "twin", cwd = "/work/b" },
  { sessionId = "dddd", name = "a-very-long-session-name", cwd = "/work/c" },
  { name = "no-id" },
}
local id, cwd, name = H.named_session(list, "fix-login")
assert(id == "aaaa" and cwd == "/work/app" and name == "fix-login")
assert(H.named_session(list, "a-very-long…") == "dddd")
assert(H.named_session(list, "twin") == nil)
assert(select(2, H.named_session(list, "twin")):find("several"))
assert(select(2, H.named_session(list, "gone")):find("no background session"))
assert(H.named_session(list, "no-id") == nil)

return "ok"
