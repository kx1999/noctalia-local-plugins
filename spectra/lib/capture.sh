#!/usr/bin/env bash
# Spectra: capture only the active media player's audio.
#
#   capture.sh <control file> <cava executable> <cava config>
#
# The control file holds the D-Bus name of the player to follow (written by
# the plugin from noctalia.mediaPlayer(); empty = none). This script finds the
# player's process, picks the PipeWire playback stream owned by that process
# or one of its children (browsers and Electron apps play from a child), and
# runs cava on that stream alone: the config's `source` is replaced by the
# stream's object.serial. cava's frames pass straight through on stdout.
# Status lines start with '#':
#   #target <serial> <bus>   capturing that stream
#   #none [bus]              no player, or it has no stream: no audio
#   #alive                   heartbeat, every 5 s
#
# It re-resolves only when the control file changes, PipeWire reports a
# playback stream appearing or disappearing (pactl subscribe), or cava exits;
# in between it only waits. Noctalia kills the whole process group (this
# script, cava and pactl) when the widget goes away.

ctl=$1
cava=$2
base=$3
run="$ctl.conf"
cpid=
cur=
lastBus=$'\x01'
dirty=1
lastStart=-10

stop_cava() {
  if [ -n "$cpid" ]; then
    kill "$cpid" 2>/dev/null
    wait "$cpid" 2>/dev/null
    cpid=
  fi
}

# Leave nothing behind when Noctalia stops the widget (it sends SIGTERM to the
# whole group first).
trap 'stop_cava; rm -f "$ctl" "$run"; exit 0' TERM INT HUP

# True when process $1 is $2 or one of its descendants.
descends() {
  local p=$1 want=$2 n=0 line rest
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$n" -lt 64 ]; do
    [ "$p" = "$want" ] && return 0
    read -r line <"/proc/$p/stat" 2>/dev/null || return 1
    rest=${line##*) } # the command name may hold spaces / parens
    set -- $rest
    p=$2
    n=$((n + 1))
  done
  return 1
}

# Print the serial of the player's playback stream (playing ones first,
# newest first), or nothing.
resolve() {
  local bus=$1 pid reply serial spid corked best= bestPlaying=
  [ -n "$bus" ] || return 0
  reply=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus \
    GetConnectionUnixProcessID s "$bus" 2>/dev/null) || return 0
  pid=${reply##* }
  [ -n "$pid" ] || return 0
  while read -r serial spid corked; do
    [ -n "$spid" ] || continue
    descends "$spid" "$pid" || continue
    if [ "$corked" = "no" ]; then
      bestPlaying=$serial
    else
      best=$serial
    fi
  done < <(pactl list sink-inputs 2>/dev/null | awk '
    /^Sink Input #/ { if (s != "") print s, p, c; s = substr($3, 2); p = ""; c = "" }
    /^[ \t]*Corked:/ { c = $2 }
    /application\.process\.id = / { gsub(/"/, "", $3); p = $3 }
    /object\.serial = / { gsub(/"/, "", $3); s = $3 }
    END { if (s != "") print s, p, c }')
  echo "${bestPlaying:-$best}"
}

start_cava() {
  stop_cava
  cur=$1
  if [ -z "$cur" ]; then
    echo "#none $bus"
    return
  fi
  lastStart=$SECONDS
  sed "s/^source = .*/source = $cur/" "$base" >"$run"
  "$cava" -p "$run" 2>/dev/null &
  cpid=$!
  echo "#target $cur $bus"
}

# Stream events wake the loop (fd 3). Without pactl, poll every 2 s instead.
events=0
if command -v pactl >/dev/null 2>&1; then
  exec 3< <(exec pactl subscribe 2>/dev/null)
  events=1
fi

echo "#alive"
lastBeat=$SECONDS
while :; do
  bus=
  if [ -e "$ctl" ]; then
    IFS= read -r bus <"$ctl" || true
  fi
  if [ "$bus" != "$lastBus" ]; then
    lastBus=$bus
    dirty=1
  fi
  if [ -n "$cpid" ] && ! kill -0 "$cpid" 2>/dev/null; then
    wait "$cpid" 2>/dev/null
    cpid=
    cur=
    dirty=1 # cava exited: find the stream again (restarts at most every 2 s)
  fi
  if [ "$dirty" = 1 ] && [ $((SECONDS - lastStart)) -ge 2 -o -z "$cpid" ]; then
    dirty=0
    target=$(resolve "$bus")
    if [ "$target" != "$cur" ] || { [ -n "$target" ] && [ -z "$cpid" ]; }; then
      start_cava "$target"
    fi
  fi
  if [ $((SECONDS - lastBeat)) -ge 5 ]; then
    echo "#alive"
    lastBeat=$SECONDS
  fi
  if [ "$events" = 1 ]; then
    if read -r -t 0.5 ev <&3; then
      case $ev in
        *"'new' on sink-input"* | *"'remove' on sink-input"*) dirty=1 ;;
      esac
    elif [ $? -le 128 ]; then
      events=0 # pactl ended: fall back to polling
    fi
  else
    sleep 2
    dirty=1
  fi
done
