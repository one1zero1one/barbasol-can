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

return "ok"
