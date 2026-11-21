# MPRIS Volume

Control one MPRIS player's own volume (the app-level `Volume` property, not
the system mixer) and playback from the shell. Uses `playerctl`. It shows no
popups; failures (player not running, etc.) go to the Noctalia log.

Set the player in the plugin settings (default `ytmdesktop`; `playerctl -l`
lists names). Instances match by prefix, and a comma-separated list picks the
first one running.

## Commands

```sh
P=kylex/mpris-volume:service
noctalia msg plugin $P all up            # +step (default 5%)
noctalia msg plugin $P all down 10       # -10%
noctalia msg plugin $P all set 40        # 40%
noctalia msg plugin $P all mute          # toggle 0% / previous volume
noctalia msg plugin $P all up player=spotify   # one-off player override
```

`up` and `set` are capped at *Maximum volume* (default 100%).

## Media controls

These only ever touch the configured player (or `player=NAME`), unlike
`noctalia msg media …` / bare `playerctl`, which act on whichever player is
currently active.

```sh
noctalia msg plugin $P all toggle        # play/pause (alias: play-pause)
noctalia msg plugin $P all play
noctalia msg plugin $P all pause
noctalia msg plugin $P all next
noctalia msg plugin $P all previous      # alias: prev; rewinds to 0:00 if >3 s in
noctalia msg plugin $P all stop
noctalia msg plugin $P all seek 10       # forward 10 s
noctalia msg plugin $P all seek -10      # back 10 s
```

## Niri keybind example

```kdl
Mod+Alt+Up   { spawn "noctalia" "msg" "plugin" "kylex/mpris-volume:service" "all" "up"; }
Mod+Alt+Down { spawn "noctalia" "msg" "plugin" "kylex/mpris-volume:service" "all" "down"; }
Mod+Alt+Space { spawn "noctalia" "msg" "plugin" "kylex/mpris-volume:service" "all" "toggle"; }
Mod+Alt+Right { spawn "noctalia" "msg" "plugin" "kylex/mpris-volume:service" "all" "next"; }
Mod+Alt+Left  { spawn "noctalia" "msg" "plugin" "kylex/mpris-volume:service" "all" "previous"; }
```
