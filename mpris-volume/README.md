# MPRIS Volume

Control one MPRIS player's own volume (the app-level `Volume` property, not
the system mixer) from the shell, with a Noctalia OSD popup. Uses `playerctl`.

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
noctalia msg plugin $P all show          # just show current volume
noctalia msg plugin $P all up player=spotify   # one-off player override
```

`up` and `set` are capped at *Maximum volume* (default 100%).

## Niri keybind example

```kdl
Mod+Alt+Up   { spawn "noctalia" "msg" "plugin" "kylex/mpris-volume:service" "all" "up"; }
Mod+Alt+Down { spawn "noctalia" "msg" "plugin" "kylex/mpris-volume:service" "all" "down"; }
```
