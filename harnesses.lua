-- The agent harnesses barbasol_can can move, loaded with dofile by init.lua (on
-- the Rex server, to find the pane's session) and by move.lua (to move it).
--
-- Each harness has:
--   match(fg)             true if the pane's foreground process is this harness
--   session(fg, title)    the session that process is in, as id, cwd, and its title if
--                         known; or nil, why. title is the pane's terminal title.
--   export                sh script, $1 = id, $2 = cwd: writes a tar.gz of the session to stdout
--   bin                   the agent's command, which the target must have
--   import                sh script run on the target after the tar.gz is unpacked into $t,
--                         with $id and $to (the target directory) set; calls fail "<why>"
--                         on failure, and resumed just before it execs the agent
--
-- session() reads what the harness itself records about a running process, so
-- it names the session that pane is in rather than the newest one in the folder.
local HOME = os.getenv("HOME")

local function sh(script, ...)
  local r = rex.exec({ "sh", "-c", script, "sh", ... })
  return r and r.ok and r.stdout or ""
end

local function readfile(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Seconds the process has been running, from ps etime ([[dd-]hh:]mm:ss).
local function age(pid)
  local e = sh('ps -o etime= -p "$1"', tostring(pid)):match("%S+")
  if not e then return nil end
  local d, rest = e:match("^(%d+)%-(.*)$")
  local n = 0
  for part in (rest or e):gmatch("%d+") do n = n * 60 + tonumber(part) end
  return n + (tonumber(d) or 0) * 86400
end

local function args(pid) return sh('ps -o args= -p "$1"', tostring(pid)) end

-- 2026-11-08T06:35:25.882Z to Unix seconds, without going through the local time zone.
local function utc(iso)
  local y, m, d, H, M, S = iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local days = era * 146097 + yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy - 719468
  return days * 86400 + tonumber(H) * 3600 + tonumber(M) * 60 + tonumber(S)
end

local H = {}

-- True for `codex exec …`, the non-interactive mode, judged by the subcommand
-- rather than the word appearing anywhere (such as in a prompt).
function H.codex_exec(args) return (args .. " "):match("^%S+%s+exec%s") ~= nil end
H.utc = utc

-- The command a process was started as. Claude Code's binary is a file named
-- after its version, so the process is called "2.1.322" rather than "claude".
function H.started_as(fg)
  return (fg.argv0 or fg.invoked_path or fg.name or ""):match("[^/]*$")
end

-- The name of the session open in an agent view (`claude agents`) pane, from
-- the pane's title: a status mark and the session's name, such as
-- "✳ fix-login". With the list showing, the title ends in "claude agents".
function H.agent_view_session(title)
  if not title or title:match("claude agents$") then return nil end
  local name = title:gsub("^[\128-\255]+%s+", "")
  return name ~= "" and name or nil
end

-- The session called name in the output of `claude agents --json`, as id, cwd,
-- name; or nil, why. A title cut short ends in "…" and matches as a prefix.
function H.named_session(list, name)
  local prefix = name:match("^(.-)…$")
  local found = {}
  for _, s in ipairs(list) do
    local n = s.name or ""
    if s.sessionId and (n == name or (prefix and n:sub(1, #prefix) == prefix)) then found[#found + 1] = s end
  end
  if #found == 0 then return nil, "no background session is named \"" .. name .. "\"" end
  if #found > 1 then return nil, "several background sessions are named \"" .. name .. "\"; rename one" end
  return found[1].sessionId, found[1].cwd, found[1].name
end

H.claude = {
  bin = "claude",
  match = function(fg) return fg.name == "claude" or H.started_as(fg) == "claude" end,
  -- Claude Code records each running instance at ~/.claude/sessions/<pid>.json.
  -- The agent view has no record of its own: the sessions it shows run under
  -- Claude Code's daemon, not in the pane. The pane's title names the one that
  -- is open, and `claude agents --json` has its id and directory.
  session = function(fg, title)
    local s = rex.json.decode(readfile(HOME .. "/.claude/sessions/" .. fg.pid .. ".json") or "null")
    if s and s.sessionId then return s.sessionId, s.cwd, s.nameSource ~= "derived" and s.name or nil end
    if not (args(fg.pid) .. " "):match("^%S+%s+agents%s") then
      return nil, "Claude Code has no session record for this process"
    end
    local name = H.agent_view_session(title)
    if not name then return nil, "no session is open in this pane; open one in the agent view first" end
    local list = rex.json.decode(sh('"$1" agents --json', fg.path or "claude"):match("%[.*%]") or "null")
    if type(list) ~= "table" then return nil, "couldn't list the background sessions" end
    return H.named_session(list, name)
  end,
  -- Sessions live under the project's cwd with every non-alphanumeric as "-",
  -- with subagent transcripts and tool results in a sibling <id>/ directory.
  -- A session that moved into a worktree keeps its transcript under the
  -- directory it started in, so fall back to finding it by id.
  export = [[
p="$HOME/.claude/projects"
d="$p/$(printf %s "$2" | sed 's/[^a-zA-Z0-9]/-/g')"
test -f "$d/$1.jsonl" || d=$(dirname "$(ls "$p"/*/"$1.jsonl" 2>/dev/null | head -n 1)")
test -f "$d/$1.jsonl" || { echo "no transcript for $1" >&2; exit 1; }
cd "$d" && tar czf - "$1.jsonl" $(test -d "$1" && echo "$1")
]],
  import = [[
p="$HOME/.claude/projects/$(printf %s "$to" | sed 's/[^a-zA-Z0-9]/-/g')"
mkdir -p "$p" && cp -R "$t"/. "$p"/ || fail "couldn't copy the session into $p"
cd "$to" || fail "no directory $to"
resumed; exec claude --resume "$id"
]],
}

H.codex = {
  bin = "codex",
  match = function(fg) return fg.name == "codex" end,
  -- Three records, most current first:
  --  * An in-process Codex logs to ~/.codex/logs_2.sqlite with pid:<pid>:<uuid>
  --    and the thread on each line. (When threads run in Codex's shared
  --    app-server daemon, they're logged under the daemon's pid instead.)
  --  * The pane title is "<thread name> | <dir>", and the thread's name is in
  --    the threads table, so it picks out the thread among those in this cwd.
  --  * `codex resume <id>` has it in the arguments before the title is set.
  -- A fresh Codex has no thread until its first turn.
  session = function(fg, title)
    local a = args(fg.pid)
    if H.codex_exec(a) then return nil, "codex exec runs non-interactively" end
    local function q(s) return "'" .. s:gsub("'", "''") .. "'" end
    local function sql(db, query) return sh('sqlite3 "$HOME/.codex/$1" "$2"', db, query) end
    local since = os.time() - (age(fg.pid) or 0) - 2
    local id = sql("logs_2.sqlite", string.format(
      "select thread_id from logs where process_uuid like 'pid:%d:%%' and thread_id is not null and ts >= %d order by id desc limit 1",
      fg.pid, since)):match("[%x%-]+")
    local name = title and title:match("^(.-) | [^|]*$")
    if not id and name and name ~= "" then
      local ids = {}
      for i in sql("state_5.sqlite", "select id from threads where cwd = " .. q(fg.cwd) .. " and name = " .. q(name)):gmatch("[%x%-]+") do
        ids[#ids + 1] = i
      end
      if #ids > 1 then return nil, "several threads here are named \"" .. name .. "\"" end
      id = ids[1]
    end
    id = id or a:match("resume%s+(%x+%-%x+%-%x+%-%x+%-%x+)")
    if not id then return nil, "Codex hasn't started a thread yet; send a message first" end
    local tname = sql("state_5.sqlite", "select coalesce(nullif(name, ''), title) from threads where id = " .. q(id)):gsub("\n$", "")
    return id, fg.cwd, tname ~= "" and tname or nil
  end,
  -- A thread is one rollout file under ~/.codex/sessions/YYYY/MM/DD/; the state
  -- databases beside it are indexes Codex rebuilds from those files.
  export = [[
f=$(find "$HOME/.codex/sessions" -name "rollout-*-$1.jsonl" | head -n 1)
test -n "$f" || { echo "no rollout for $1" >&2; exit 1; }
cd "$HOME/.codex" && tar czf - "${f#$HOME/.codex/}"
]],
  import = [[
mkdir -p "$HOME/.codex" && cp -R "$t"/. "$HOME/.codex"/ || fail "couldn't copy the thread into ~/.codex"
cd "$to" || fail "no directory $to"
resumed; exec codex resume -C "$to" "$id"
]],
}

H.opencode = {
  bin = "opencode",
  match = function(fg) return fg.name == "opencode" end,
  -- opencode processes share one log and tag their lines run=<id>. A run starts
  -- with "creating instance" for its directory, at the process's start time, and
  -- logs session.id= when it works on a session. Without a turn yet, -s <id> in
  -- its arguments names the session. The pane title ("OC | <title>") must agree.
  session = function(fg, title)
    local start = os.time() - (age(fg.pid) or 0)
    local runs, sid, run = {}, {}, nil
    local log = io.open(HOME .. "/.local/share/opencode/log/opencode.log")
    for line in (log and log:lines() or function() end) do
      local ts, r = line:match("^timestamp=(%S+) level=%S+ run=(%S+)")
      if r then
        if (line .. " "):find('message="creating instance" directory=' .. fg.cwd .. " ", 1, true) then
          local t = utc(ts)
          if t and math.abs(t - start) <= 3 then runs[r] = true end
        end
        sid[r] = line:match("session%.id=(ses_[%w]+)") or sid[r]
      end
    end
    if log then log:close() end
    for r in pairs(runs) do
      if run then return nil, "two opencode processes started together here; can't tell them apart" end
      run = r
    end
    local a = args(fg.pid)
    local id = (run and sid[run]) or a:match("%-%-session[=%s]+(ses_%w+)") or a:match("%-s%s+(ses_%w+)")
    if not id then return nil, "opencode hasn't opened a session yet" end
    local got = sh(string.format("sqlite3 \"$HOME/.local/share/opencode/opencode.db\" \"select title from session where id='%s'\"", id)):gsub("\n$", "")
    local want = title and title:match("^OC | (.+)$")
    if want and got ~= "" and got:sub(1, #want) ~= want and want:sub(1, #got) ~= got then
      return nil, "found session \"" .. got .. "\" but the pane shows \"" .. want .. "\""
    end
    return id, fg.cwd, got ~= "" and got or nil
  end,
  -- opencode keeps sessions in SQLite, so it moves with its own export and import.
  export = [[
d=$(mktemp -d) || exit 1
opencode export "$1" > "$d/session.json" && tar czf - -C "$d" session.json
rc=$?; rm -rf "$d"; exit $rc
]],
  -- import binds the session to the directory it runs in.
  import = [[
cd "$to" || fail "no directory $to"
opencode import "$t/session.json" >/dev/null || fail "opencode import failed"
resumed; exec opencode -s "$id"
]],
}

H.order = { "claude", "codex", "opencode" }

-- The harness running in the foreground process, as name, harness.
function H.detect(fg)
  if not fg then return nil end
  for _, name in ipairs(H.order) do
    if H[name].match(fg) then return name, H[name] end
  end
end

return H
