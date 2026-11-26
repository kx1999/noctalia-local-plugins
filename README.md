# Noctalia local plugins

Personal [Noctalia](https://github.com/noctalia-dev/noctalia) (v5) plugins,
loaded straight from this folder as the `local-plugins` plugin source.

| Plugin | ID | What it does |
| --- | --- | --- |
| [MPRIS Volume](#mpris-volume) | `kylex/mpris-volume` | Volume and playback control for one chosen MPRIS player |
| [Extent OSD](#extent-osd) | `kylex/extent-osd` | OSD popup when an Umbriel window's width/height extent changes |
| [Discord Voice](#discord-voice) | `raycursive/discord-voice` | Bar widget + panel for a local Discord voice session |
| [Spectra](#spectra) | `kylex/spectra` | Audio visualizer for the bar, desktop and lock screen, with 20 shapes |

## Setup

This folder (`~/.local/share/noctalia-local-plugins`) is registered as a path
source in Noctalia:

```sh
noctalia msg plugins source add local-plugins ~/.local/share/noctalia-local-plugins   # one-time
noctalia msg plugins source list
```

`catalog.toml` lists every plugin in the folder. It's local-only and
gitignored, so a fresh clone needs one; copy an entry's `id`, `name`,
`version`, `author`, `license`, `icon`, `description`, `plugin_api` and
`tags` from each `plugin.toml`. Each plugin lives in its own
directory with a `plugin.toml` manifest, Luau entries, and
`translations/en.json`.

```sh
noctalia msg plugins update local-plugins          # pick up new plugins / manifest changes
noctalia msg plugins enable kylex/mpris-volume     # enable / disable by ID
noctalia msg plugins list | grep local-plugins     # installed versions and state
noctalia msg settings-open-plugin kylex/mpris-volume   # open a plugin's settings
noctalia plugins lint mpris-volume                 # check a plugin's settings vs. code
```

Edits to `.luau` files hot-reload automatically. Changes to `plugin.toml`
(new settings, version bumps) need `plugins update`, and sometimes a
`plugins disable` + `plugins enable`, before Noctalia sees them. When adding
a plugin, also add its entry to `catalog.toml`.

All plugin commands go through `noctalia msg plugin <id>:<entry> all <event> [payload]`.
Plugin log output lands in `~/.cache/noctalia/noctalia.log`.

---

## MPRIS Volume

`kylex/mpris-volume` · service entry `service` · requires `playerctl`

Controls **one specific MPRIS player**, for example `ytmdesktop`, and never
touches other players. That differs from `noctalia msg media …` and plain
`playerctl`, which act on whichever player is active. Volume is the player's
own app-level volume, not the system mixer. It shows no popups; failures such
as "player not running" go to the log.

### Commands

```sh
# Volume
noctalia msg plugin kylex/mpris-volume:service all up          # +step (default 5%)
noctalia msg plugin kylex/mpris-volume:service all down 10     # -10%
noctalia msg plugin kylex/mpris-volume:service all set 40      # set to 40%
noctalia msg plugin kylex/mpris-volume:service all mute        # toggle 0% / previous volume

# Playback
noctalia msg plugin kylex/mpris-volume:service all toggle      # play/pause (alias: play-pause)
noctalia msg plugin kylex/mpris-volume:service all play
noctalia msg plugin kylex/mpris-volume:service all pause
noctalia msg plugin kylex/mpris-volume:service all next
noctalia msg plugin kylex/mpris-volume:service all previous    # alias: prev (see below)
noctalia msg plugin kylex/mpris-volume:service all stop
noctalia msg plugin kylex/mpris-volume:service all seek 10     # forward 10 s; -10 goes back

# Any command can target another player once:
noctalia msg plugin kylex/mpris-volume:service all next player=spotify
```

`previous` behaves like most players' back button. More than 3 s into a
track, it rewinds to 0:00; pressed again near the start, it goes to the
previous track.

### Settings

| Setting | Default | Description |
| --- | --- | --- |
| Player | `ytmdesktop` | playerctl name (`playerctl -l` lists them). `firefox` also matches `firefox.instance_…`; a comma-separated list uses the first one running. |
| Step (%) | `5` | Default amount for `up` / `down`. |
| Maximum volume (%) | `100` | Cap for `up` / `set` (some players allow >100%). |
| Previous: restart after (s) | `3` | Threshold for `previous` rewinding instead of skipping. `0` always skips. |

### Keybinds (Umbriel, `~/.config/umbriel/keybinds.toml`)

```toml
"Mod+Left"   = { action = "spawn noctalia msg plugin kylex/mpris-volume:service all previous", allow_when_locked = true }
"Mod+Right"  = { action = "spawn noctalia msg plugin kylex/mpris-volume:service all next", allow_when_locked = true }
"Mod+Up"     = { action = "spawn noctalia msg plugin kylex/mpris-volume:service all up", allow_when_locked = true }
"Mod+Down"   = { action = "spawn noctalia msg plugin kylex/mpris-volume:service all down", allow_when_locked = true }
"Mod+Return" = { action = "spawn noctalia msg plugin kylex/mpris-volume:service all toggle", allow_when_locked = true }
```

Tip for typing it in fish: `function mp; noctalia msg plugin kylex/mpris-volume:service all $argv; end; funcsave mp`, then `mp next`, `mp up 10`, and so on.

More detail: [`mpris-volume/README.md`](mpris-volume/README.md).

---

## Extent OSD

`kylex/extent-osd` · service entry `service` · requires the `umbriel` compositor

Shows a Noctalia OSD whenever the focused Umbriel window's primary or
secondary extent changes. That covers `window-cycle-*-extent`,
`window-modify-*-extent`, `window-set-*-extent`, keyboard resizes and mouse
resizes. There's nothing to bind: once enabled, it listens to
`umbriel subscribe` on its own.

- Tiled windows show a percentage with a progress bar: `Width 50%`, `Height 100%`.
- Floating windows show pixels: `Width 1200px`.
- When both axes change at once, as in a corner drag, it shows `50% × 100%` or `1200 × 1200 px`.
- The label is always the physical side that changed, including on rotated or portrait outputs.

### Commands

```sh
noctalia msg plugin kylex/extent-osd:service all test   # preview the popup
umbriel msg window-cycle-primary-extent                 # trigger it for real
```

### Settings

| Setting | Default | Description |
| --- | --- | --- |
| Layout gap | `8` | Must match Umbriel `layout.gap` for percentages to be exact. |
| Border width | `2` | Must match Umbriel `appearance.border_width`. |
| Title bar height | `28` | Must match Umbriel `appearance.title_bar.height`. |
| Show pixel size on tiled windows | off | Append `(1200px)` to percentages. |
| Include floating windows | on | Also show the popup (in pixels) for floating windows. |
| Minimum change | `2` px | Ignore smaller size changes. |
| Combine axes window | `300` ms | Keep the combined W × H form during a drag instead of flickering. `0` disables. |

More detail: [`extent-osd/README.md`](extent-osd/README.md).

---

## Discord Voice

`raycursive/discord-voice` (vendored from raycursive) · entries: bar widget
`bar`, panel `panel`, service `bridge` · requires `python3` ≥ 3.10 and the
Discord desktop client (not the web app)

Shows and controls your local Discord voice session: mute, deafen, hang up,
your input volume (0–100%), per-participant listening volume (0–200%), and
recent/favorite channels.

### First use

1. Enable the plugin, then add the `bar` widget in **Settings → Bar → Widgets**.
2. Click the widget to open the panel. If Discord isn't running, the first click launches it.
3. Click **Authorize Discord** and accept Discord's consent prompt. The token has no refresh, so authorize again when it expires.

### Commands

```sh
noctalia msg panel-toggle raycursive/discord-voice:panel                  # open the panel without the bar widget
noctalia msg plugin raycursive/discord-voice:bridge all toggle-mute
noctalia msg plugin raycursive/discord-voice:bridge all toggle-deaf
noctalia msg plugin raycursive/discord-voice:bridge all hangup
noctalia msg plugin raycursive/discord-voice:bridge all join-favorite-1   # favorite slots 1-5 (numbers shown in the panel)
noctalia msg plugin raycursive/discord-voice:bridge all authorize
noctalia msg plugin raycursive/discord-voice:bridge all refresh
noctalia msg plugin raycursive/discord-voice:bridge all dump              # token-free state summary to the log
```

The bridge can also be run directly; it prints JSON:
`python3 ~/.local/share/noctalia-local-plugins/discord-voice/discord_bridge.py command status`.

### Settings

| Setting | Default | Description |
| --- | --- | --- |
| Discord executable | `/usr/bin/discord` | Used to launch Discord and open channel links. |
| Glyph *(per widget)* | `brand-discord` | Icon shown when no participant avatar is displayed. |
| Show channel name *(per widget)* | on | Show the voice channel name next to the icon. |
| Hide when disconnected *(per widget)* | off | Hide the widget when not in a voice channel. |

Token storage, privacy notes and more: [`discord-voice/README.md`](discord-voice/README.md).

---

## Spectra

`kylex/spectra` · entries: bar widget `bar`, desktop / lock-screen widget
`desktop`, panel `gallery` · the desktop widget requires `cava`

A highly customizable audio visualizer with 20 shapes: bars, LED blocks,
dots, dot matrix, bubbles, lollipops, falling peaks, wave, filled area, text
blocks, braille, spectrogram, bass/mid/treble meter, pulse orb, radial bars,
orbit dots, circle wave, bloom, spiral and concentric rings. Colors follow the
Noctalia palette by default. Resolution, spacing, bar width, roundness, peaks,
glow, dynamics and idle behaviour are all set per widget instance.

- **Bar:** add **Spectra** in Settings → Bar → Widgets. Audio comes from
  Noctalia's built-in PipeWire spectrum.
- **Desktop / lock screen:** add **Spectra** with
  `noctalia msg desktop-widgets-edit` or `noctalia msg lockscreen-widgets-edit`.
  Each instance runs its own cava and, with the default **Auto** aspect,
  fills its box at any size.
  The editor shows one group of settings at a time; switch groups with
  **Settings page**.
- **Pause while fullscreen:** on by default. Each widget hides and stops
  drawing while a fullscreen window (a game, a video) covers its output, and
  comes back when it leaves. It listens to compositor window events through
  `noctalia.compositor.subscribe`, so nothing polls. Works on Umbriel.

### Commands

```fish
noctalia msg panel-toggle kylex/spectra:gallery                # every shape, animated
noctalia msg plugin kylex/spectra:desktop all shape radial     # runtime preview (not saved)
noctalia msg plugin kylex/spectra:bar all next                 # cycle shapes; also prev / demo / reset / info
```

### Settings

Every setting is per widget instance. These control how much work it does:

| Setting | Default | Description |
| --- | --- | --- |
| Resolution | `24` bar / `64` desktop | Number of bands (4–128 on the bar, 4–256 on the desktop). |
| Max frame rate | `60` | Upper limit on redraws per second (10–240). The desktop's cava runs at the same rate, capped at 200. |
| When silent | fade | `keep`, `fade`, `hide` or `breathe`. Drawing stops once it settles. |
| Silent opacity | `0.35` | Opacity used by `fade`. |
| Silence delay | `2000` ms | How long audio must stay silent before the silent behaviour starts. |
| Only while media plays | off | Ignore audio unless an MPRIS player is playing (skips game audio, notifications and calls). |
| Pause while fullscreen | on | Hide and stop drawing while a fullscreen window covers this output. |

Shape, layout, colors, peaks, glow, dynamics and the cava input are covered in
[`spectra/README.md`](spectra/README.md). Settings are generated from
`spectra/tools/gen_manifest.py` (run `python3 spectra/tools/gen_manifest.py`
after editing it). Self-tests run inside the gallery panel; see the plugin
README.
