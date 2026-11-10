-- barbasol_can: a Rex plugin that moves a running agent session (Claude Code,
-- Codex or opencode) to another host.
--
-- Adds "Move Agent Session…" to the command palette. Run it on a pane running
-- an agent; a floating picker asks for the host, a Rex session and a directory
-- there, and the session resumes on that host.

-- Rex names this chunk relative to the config file's directory, e.g. "barbasol_can/init.lua".
local function config_dir()
  local c = os.getenv("REX_CONFIG")
  if c then return c:match("^(.*)/[^/]*$") end
  return (os.getenv("XDG_CONFIG_HOME") or os.getenv("HOME") .. "/.config") .. "/rex"
end
local here = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]*$")
if here:sub(1, 1) ~= "/" then here = config_dir() .. "/" .. here end
local H = dofile(here .. "/harnesses.lua")
local T = "com.superlogical.terminal"

rex.action{
  name = "barbasol_can",
  title = "Move Agent Session…",
  category = "Agents",
  keywords = "claude codex opencode agent session move push resume transfer host",
  run = function(ctx)
    -- On a pane of another server, the calls below reach that server while the
    -- session lookup and the export read this machine, which could pick a
    -- session here that only shares a pid or a name.
    if ctx.server then
      error("Can't move from " .. tostring(ctx.server) .. " yet: run this on a pane of the machine the plugin is installed on", 0)
    end
    local p = rex.block.call(T, "process", { block_id = ctx.block_id })
    local fg = p and p.foreground
    local name, h = H.detect(fg)
    if not h then
      error("Nothing to move: this pane isn't running Claude Code, Codex or opencode", 0)
    end
    local t = rex.block.call(T, "title", { block_id = ctx.block_id })
    local id, cwd, title = h.session(fg, t and t.title)
    if not id then error("Can't move this " .. name .. " session: " .. cwd, 0) end
    -- The app that ran the action, so the picker can have that app show the
    -- moved session. Its connection to the target host has the same label.
    local c = ctx.client_id and rex.call("client.inspect", { client_id = ctx.client_id })
    local app = c and c.client.info.kind == "app" and c.client.info.label or ""
    -- Aim for an 80-column picker: the share of the pane's width that gives it,
    -- kept between 35% (big windows) and 90% (small ones). The pane is usually
    -- the whole window's width; in a split this errs wider.
    local size = rex.block.call(T, "size", { block_id = ctx.block_id })
    local w = math.min(0.9, math.max(0.35, 80 / ((size and size.columns) or 80)))
    local _, err = rex.session.new_layer{
      bounds = { (1 - w) / 2, 0.2, w, 0.5 }, -- x, y, width, height as fractions of the window
      focus = true,
      layout = rex.layout.block{
        flavor = T .. ".shell",
        label = "Move Agent Session",
        options = { command = { "sh", here .. "/pick.sh", name, id, cwd, title or "", app, ctx.block_id } },
      },
    }
    if err then error(err, 0) end
  end,
}
