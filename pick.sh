#!/bin/sh
# Pick a host, a Rex session and a directory there, then move an agent session to it.
# usage: pick.sh <harness> <session-id> <session-cwd> [<title> [<app label> [<source block>]]]
harness=$1 id=$2 dir=$3 title=$4 app=$5 src=$6
from=${app:-$(hostname -s)}
move="$(dirname "$0")/move.lua"
step() { rex do "$move" "$@"; }
fail() { printf '\n%s\n\nPress Enter to close.' "$*"; read -r _; exit 1; }
command -v gum >/dev/null || fail "barbasol_can needs gum: brew install gum"

# A step under a spinner: its output on stdout, its error kept in $errf for fail.
errf=$(mktemp) || exit 1
spin() { label=$1; shift; gum spin --show-stdout --title "$label" -- sh -c 'exec rex do "$@" 2>"$0"' "$errf" "$move" "$@"; }
why() { sed 's/^Error: //' "$errf"; }

hosts=$(step cmd=hosts) || fail "Couldn't list hosts."
[ -n "$hosts" ] || fail "No other hosts. Add one with: rex hosts"
name=${title:-$(printf %.8s "${id#ses_}")}
host=$(printf '%s\n' "$hosts" | gum choose --header "Move $harness · $name to…") || exit 0

tab=$(printf '\t')
sessions=$(step cmd=sessions host="$host") || fail "Couldn't list sessions on $host."
session=$({ printf '+ New session%snew\n' "$tab"; [ -z "$sessions" ] || printf '%s\n' "$sessions"; } |
  gum choose --label-delimiter "$tab" --header "Rex session on $host") || exit 0
[ "$session" = new ] && session= || session="session=$session"

# open removes its receiver itself if it fails.
ids=$(spin "Connecting to $host…" cmd=open host="$host" h="$harness" id="$id" from="$from" title="$title" $session) ||
  fail "Couldn't start a receiver on $host: $(why)"
read -r sid bid wid <<EOF
$ids
EOF
sent=
trap '[ -n "$sent" ] || step cmd=close host="$host" sid="$sid" wid="$wid" >/dev/null 2>&1; rm -f "$errf"' EXIT

# Start in the same path on the remote, or its home when that doesn't exist.
lsdir() { step cmd=ls host="$host" sid="$sid" bid="$bid" path="$1" 2>/dev/null; }
listing=$(lsdir "$dir") || listing=$(lsdir "~") || fail "Couldn't list directories on $host."
while :; do
  path=$(printf '%s\n' "$listing" | head -n 1)
  choice=$({ printf '✓ Resume in %s\n..\n' "$path"; printf '%s\n' "$listing" | tail -n +2; } |
    gum filter --no-strict --height 15 --header "$host: $path" --placeholder "Filter, or type a path") || exit 0
  case $choice in
    "✓ Resume in "*) break ;;
    /* | "~"*) next=$choice ;;
    *) next=$path/$choice ;;
  esac
  if new=$(lsdir "$next"); then listing=$new; else gum log --level warn "$next doesn't exist on $host"; fi
done

# From here the receiver is send's to keep or remove: it removes it if the
# export fails before anything is sent, and otherwise leaves it showing why.
sent=1
spin "Sending $name to $host:$path…" cmd=send host="$host" sid="$sid" bid="$bid" wid="$wid" \
  h="$harness" id="$id" dir="$dir" to="$path" src="$src" >/dev/null || fail "Moving failed: $(why)"
gum style --border rounded --padding "0 1" "Resumed $name on $host" "in $path"
# Have this app show the moved session, through its connection to that host.
[ -n "$app" ] && gum confirm --default=true "Switch to it now?" &&
  { step cmd=show host="$host" sid="$sid" wid="$wid" app="$app" 2>"$errf" || fail "Couldn't switch to it: $(why)"; }
exit 0
