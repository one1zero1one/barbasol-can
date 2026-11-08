# barbasol-can

A [Rex](https://www.superlogical.com/rex) plugin that moves a running agent
session to another Rex host. It supports Claude Code, Codex and opencode.

The name comes from Jurassic Park, where Nedry tries to smuggle dinosaur
embryos off the island in a Barbasol shaving-cream can. Rex's mascot is a
dinosaur, and this smuggles agent sessions between Rex servers.

Run **Move Agent Session…** from the command palette while a pane running an
agent is focused. A floating picker asks which host to move to, which Rex
session there to use (a new one, or a new tab in an existing one), and which
directory to resume in. The session then resumes on that host.

While it moves, the new tab on the target shows its progress in Rex's activity
indicators (waiting, receiving, importing), then a done marker reading
"Resumed <title> from <machine>", or a failed one with the reason. The tab is
named after the session's title, the original pane is labelled
`moved to <host>`, and the picker offers to switch the app you ran it from to
the moved session.

If the pane can't be moved, the action says why instead: it isn't running a
supported agent, the agent hasn't started a session yet, or the session it's
in can't be pinned down.

## Install

Needs [gum](https://github.com/charmbracelet/gum) on the machine you move from,
and the agent's CLI on the machine you move to. Nothing else is installed on
the target.

```sh
brew install gum
git clone https://github.com/pthm/barbasol-can ~/.config/rex/agent_move
echo 'require("agent_move")' >> ~/.config/rex/init.lua
rex config reload
```

Hosts come from `rex hosts`. Bind a key with
`rex.bind("cmd+shift+m", "agent_move")`.

## Finding the pane's session

Each agent is identified by the pane's foreground process, and its session by
what that agent records about the running process, not by which session is
newest:

| Agent | Session |
| --- | --- |
| Claude Code | `~/.claude/sessions/<pid>.json` |
| Codex | Its logs (`pid:<pid>` with the thread) when the thread runs in-process; otherwise the pane title (`<thread name> \| <dir>`) matched against the thread names in that directory; otherwise `codex resume <id>` in its arguments |
| opencode | The `run=` in its shared log that started with the process, and the last session that run worked on; otherwise `-s <id>` in its arguments. The pane title (`OC \| <title>`) must agree |

## Moving it

`move.lua` opens a terminal on the target host and streams the exported
session into it through the pty. The terminal unpacks it, imports it the
agent's way, and resumes it:

| Agent | Export | Import and resume |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/<dir>/<id>.jsonl` and its `<id>/` folder | Copied under the target directory's project, `claude --resume <id>` |
| Codex | The thread's rollout file in `~/.codex/sessions/` | Copied to the same path, `codex resume -C <dir> <id>` |
| opencode | `opencode export <id>` | `opencode import` in the target directory, `opencode -s <id>` |

The receiver reports how it ended as a Rex program status record: `done`
just before it starts the agent, or `error` with the reason. The picker waits
for that before saying the session resumed, and shows the reason when it
didn't. A receiver that fails keeps its tab open with the error; one that never
received anything is removed.

The same terminal serves the picker's directory listings, so they show the
target's filesystem. Each agent is one entry in `harnesses.lua`. Run
`rex do check.lua` to check its parsing, and `rex config reload` after
changing it.

The original session keeps running where it was. The two copies diverge from
the moment of the move.
