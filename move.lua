-- Steps for moving an agent session to another Rex host, run with `rex do`.
-- pick.sh drives them; each prints plain lines for the shell. <h> is a harness
-- name from harnesses.lua.
--
--   cmd=hosts                                  host labels, one per line
--   cmd=sessions host=                         "<label>\t<session id>" per Rex session there
--   cmd=open  host= h= id= from= [title=] [session=]
--                                              start a receiver there; prints "<session> <block> <window>"
--   cmd=ls    host= sid= bid= path=            resolved path, then its subdirectories
--   cmd=send  host= sid= bid= wid= h= id= dir= to=
--                                              send session <id> from <dir>, resume it in <to>,
--                                              and wait until the receiver says it resumed; then
--                                              label the source pane src= (on this server) as moved
--   cmd=show  host= sid= wid= app=             have the app labelled <app> show the moved session
--   cmd=close host= sid= [wid=]                drop an unused receiver (its window, or its session)
--
-- Nothing is installed on the target. The receiver is a terminal on that host:
-- the session is streamed in through its pty, unpacked, imported the harness's
-- way, and resumed. The receiver's terminal also serves the
-- remote directory listings, since list_dir runs where the terminal does.
local T = "com.superlogical.terminal"
local a = rex.args
local srv = a.host and rex.server(a.host)
local here = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]*$") or "."
local H = dofile(here .. "/harnesses.lua")
local h = a.h and (H[a.h] or error("unknown harness " .. a.h, 0))
-- rex do types key=value by how it looks, so a title like 123 arrives as a number.
for _, k in ipairs{ "title", "from", "app" } do if a[k] ~= nil then a[k] = tostring(a[k]) end end

-- At most n bytes of s, cut before a UTF-8 character rather than inside one.
local function clip(s, n)
  if #s <= n then return s end
  local cut, next = s:sub(1, n), s:byte(n + 1)
  if next >= 128 and next < 192 then cut = cut:gsub("[\192-\255][\128-\191]*$", "") end
  return cut .. "…"
end

local function term(method, args)
  args.session_id, args.block_id = a.sid, a.bid
  local r, e = srv.block.call(T, method, args)
  if not r then error(method .. ": " .. tostring(e), 0) end
  return r
end

-- The receiver reports how it ended as a program status record (OSC 7501) with
-- id "barbasolcan": done just before it execs the agent, or error with the
-- reason. Records outlive the exec and the agent's own reports use other ids,
-- so this is what the sender checks, rather than the screen, which the agent
-- replaces as soon as it starts.
local function outcome()
  for _, r in ipairs(term("program_status", {}).records or {}) do
    if r.id == "barbasolcan" then return r.state, r.msg end
  end
end

-- Wait for marker on the receiver's screen, or with marker nil for its done
-- record. An error record fails the wait with the receiver's reason.
local function wait_for(marker, secs)
  for _ = 1, (secs or 10) * 10 do
    local state, msg = outcome()
    if state == "error" then error(msg or "the receiver failed", 0) end
    if marker == nil and state == "done" then return end
    if marker and (term("format", { trim = true }).content or ""):find(marker, 1, true) then return end
    rex.sleep(0.1)
  end
  error("timed out waiting for the receiver" .. (marker and " to print " .. marker or " to resume"), 0)
end

-- -echo keeps the payload off the screen. The two header lines are read in
-- canonical mode; the payload then needs -icanon, because canonical mode caps
-- a line at MAX_CANON, so the sender waits for REX-GO before writing it.
-- The harness's import script follows, with $t, $to and $id set and fail()
-- and resumed() to report how it ended. $2 is the agent's command, $3 the
-- machine it comes from, $4 the session's title. The working records show as a
-- spinner on the tab while it waits, receives and imports.
local RECV = [[
st() { printf '\033]7501;id=barbasolcan:app=barbasol_can:state=%s:msg=%s\033\\' "$1" "$(printf %s "$2" | base64 | tr -d '\n')"; }
fail() { st error "$*"; echo "barbasol_can: $*"; exit 1; }
id=$1 from=$3 what=${4:-$1}
resumed() { st done "Resumed $what from $from"; }
command -v "$2" >/dev/null || fail "$2 isn't installed on this host"
st working "Waiting for $what from $from"
stty -echo; echo REX-READY
IFS= read -r to; IFS= read -r n
t=$(mktemp -d) || fail "can't make a temporary directory"
st working "Receiving $what from $from"
stty -icanon; echo REX-GO
head -c "$n" | base64 --decode | tar xzf - -C "$t" || fail "unpack failed"
stty sane 2>/dev/null
st working "Importing $what"
]]

local cmd = {}

function cmd.hosts()
  for _, h in ipairs(rex.servers()) do print(h) end
end

function cmd.sessions()
  local r, err = srv.call("session.list", {})
  if not r then error(err, 0) end
  for _, x in ipairs(r.sessions or {}) do print(x.label .. "\t" .. x.session_id) end
end

-- Without session=, the receiver gets a session of its own; with it, a new
-- window in that session. Prints "<session> <block> <window or ->".
function cmd.open()
  local window = {
    window_label = a.h .. " · " .. (a.title and a.title ~= "" and clip(a.title, 40) or a.id:gsub("^ses_", ""):sub(1, 8)),
    layout = rex.layout.block{
      flavor = T .. ".shell",
      options = { command = { "sh", "-c", RECV .. h.import, "sh", a.id, h.bin, a.from or "another host", a.title or "" }, exit = { on_completion = false } },
    },
  }
  local wid = "-"
  if a.session then
    a.sid = a.session
    assert(srv.session.attach{ session_id = a.sid })
    window.session_id = a.sid
    local w, err = srv.call("session.new_window", window)
    if not w then error(err, 0) end
    a.bid, wid = w.block_ids[1], w.window_id
  else
    local r, err = srv.call("session.create", { label = window.window_label, initial_windows = { window } })
    if not r then error(err, 0) end
    a.sid, a.bid = r.session_id, r.initial_windows[1].block_ids[1]
    assert(srv.session.attach{ session_id = a.sid })
  end
  -- The receiver exists now, so a failure from here on removes it again.
  a.wid = wid
  local ok, err = pcall(wait_for, "REX-READY")
  if not ok then pcall(cmd.close) error(err, 0) end
  print(a.sid .. " " .. a.bid .. " " .. wid)
end

function cmd.ls()
  assert(srv.session.attach{ session_id = a.sid })
  local r = term("list_dir", { path = a.path })
  if r.status ~= "ok" then error(a.path .. ": " .. r.status, 0) end
  local names = {}
  for _, e in ipairs(r.entries or {}) do
    if e.name:sub(1, 1) ~= "." then names[#names + 1] = e.name end
  end
  table.sort(names)
  print(r.path)
  for _, n in ipairs(names) do print(n) end
end

function cmd.send()
  assert(srv.session.attach{ session_id = a.sid })
  -- Through a file, so a failed export isn't hidden by the pipe into base64.
  local r, err = rex.exec({ "sh", "-c",
    'f=$(mktemp) || exit 1; (' .. h.export .. ') > "$f" && base64 < "$f" | tr -d "\\n"; rc=$?; rm -f "$f"; exit $rc',
    "sh", a.id, a.dir })
  if not (r and r.ok) then
    -- Nothing has reached the receiver, so it's still waiting; remove it.
    pcall(cmd.close)
    local why = r and (r.stderr ~= "" and r.stderr or "exit " .. r.code) or err
    error("export failed: " .. why, 0)
  end
  local data = r.stdout
  term("write", { data = a.to .. "\n" .. #data .. "\n" })
  wait_for("REX-GO")
  local CHUNK = 60 * 1024 -- control messages cap at 64 KiB including the JSON envelope
  for i = 1, #data, CHUNK do term("write", { data = data:sub(i, i + CHUNK - 1) }) end
  wait_for(nil, 60)
  -- The source keeps running, so mark it as the stale copy.
  if a.src and a.src ~= "" then rex.session.set_block_label{ block_id = a.src, label = "moved to " .. a.host } end
end

function cmd.show()
  local r, err = srv.call("client.list", {})
  if not r then error(err, 0) end
  for _, c in ipairs(r.clients or {}) do
    if c.info and c.info.kind == "app" and c.info.label == a.app and c.connection_state == "connected" then
      local ok, e = srv.call("client.perform", {
        client_id = c.client_id,
        action = "session.select",
        args = { session_id = a.sid, window_id = a.wid ~= "-" and a.wid or nil },
      })
      if not ok then error(e, 0) end
      return
    end
  end
  error(a.app .. " isn't connected to " .. a.host, 0)
end

function cmd.close()
  assert(srv.session.attach{ session_id = a.sid })
  if a.wid and a.wid ~= "-" then
    assert(srv.call("session.close_window", { session_id = a.sid, window_id = a.wid }))
  else
    assert(srv.call("session.destroy", { session_id = a.sid }))
  end
end

local f = cmd[a.cmd]
if not f then error("cmd must be one of hosts, sessions, open, ls, send, show, close", 0) end
f()
