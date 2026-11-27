#!/usr/bin/env python3
"""Generate plugin.toml and translations/en.json for kylex/spectra.

The bar widget and the desktop widget share almost every setting, and
Noctalia manifests cannot share setting blocks between entries, so both files
are generated from the single table below. Edit SETTINGS / the header here and
re-run:

    python3 tools/gen_manifest.py

Defaults that differ per entry are given as {"bar": x, "desktop": y}. Keep
them in sync with the DEFAULTS tables at the top of bar.luau / desktop.luau.
"""

import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

VERSION = "1.1.0"

SHAPES = [
    ("bars", "Bars"),
    ("blocks", "LED blocks"),
    ("dots", "Floating dots"),
    ("dot_matrix", "Dot matrix"),
    ("bubbles", "Bubbles"),
    ("lollipops", "Lollipops"),
    ("peaks", "Falling peaks"),
    ("wave", "Wave line"),
    ("area", "Filled area"),
    ("text", "Text blocks ▁▃▅▇"),
    ("braille", "Braille ⣀⣤⣶⣿"),
    ("spectrogram", "Spectrogram (waterfall)"),
    ("meter", "Bass / mid / treble meter"),
    ("pulse", "Pulse orb"),
    ("radial", "Radial bars"),
    ("radial_dots", "Orbit dots"),
    ("circle_wave", "Circle wave"),
    ("bloom", "Bloom (petals)"),
    ("spiral", "Spiral"),
    ("rings", "Concentric rings"),
]

LINEAR = ["bars", "blocks", "dots", "dot_matrix", "bubbles", "lollipops", "peaks", "wave", "area",
          "text", "braille", "spectrogram", "meter"]
RADIAL_DIR = ["radial", "radial_dots", "circle_wave"]
RADIAL_ALL = ["radial", "radial_dots", "circle_wave", "bloom", "spiral", "rings"]
WIDTH_SHAPES = ["bars", "blocks", "dots", "dot_matrix", "bubbles", "lollipops", "peaks", "spectrogram",
                "radial", "radial_dots", "bloom", "spiral"]
ROUND_SHAPES = ["bars", "blocks", "peaks", "spectrogram", "meter", "radial", "spiral"]


def vis(key, *values):
    return {"key": key, "values": list(values)}


def shapes(*names):
    return vis("shape", *names)


# Each entry: key, type, default, label, description (or None), extras.
# scope: "both" (default), "bar", "desktop".
SETTINGS = [
    # ── Shape & layout ───────────────────────────────────────────────────
    dict(key="shape", type="select", default="bars", label="Shape",
         description="How the spectrum is drawn. Radial shapes look best on a square desktop widget.",
         options=SHAPES),
    dict(key="baseline", type="select", default="bottom", label="Baseline",
         description="Where linear shapes grow from. Center mirrors them up and down. On a vertical bar, bottom means the left edge.",
         options=[("bottom", "Bottom"), ("center", "Center (mirrored)"), ("top", "Top")],
         visible_when=shapes(*LINEAR)),
    dict(key="frequency_layout", type="select", default="auto", label="Frequency layout",
         description="Order of frequencies along the shape. Auto uses low → high for linear shapes and bass-centered mirroring for radial ones.",
         options=[("auto", "Auto"), ("low_high", "Low → high"), ("high_low", "High → low"),
                  ("mirror_center", "Mirrored, bass in the center"), ("mirror_edges", "Mirrored, bass at the edges")]),
    dict(key="audio_spectrum_bands", type="int", default={"bar": 24, "desktop": 64},
         min={"bar": 4, "desktop": 4}, max={"bar": 128, "desktop": 256}, step=1,
         label="Resolution (bands)",
         description="Number of bars / points drawn. Mirrored layouts analyse half as many bands and draw each twice."),

    # ── Size & spacing ───────────────────────────────────────────────────
    dict(key="length", type="int", default=140, min=16, max=1200, step=2, scope="bar",
         label="Length", description="Widget length along the bar, in px (before the bar's scale)."),
    dict(key="thickness", type="int", default=20, min=4, max=96, step=1, scope="bar",
         label="Thickness", description="Widget size across the bar, in px. Radial shapes use a square of this size."),
    dict(key="aspect", type="select", default="auto", scope="desktop", label="Canvas aspect ratio",
         description="Auto fills the whole widget box at any size. A fixed ratio keeps that proportion and is centered in the box.",
         options=[("auto", "Auto (fill the box)"), ("1:1", "1:1"), ("4:3", "4:3"), ("16:9", "16:9"), ("2:1", "2:1"),
                  ("3:1", "3:1"), ("4:1", "4:1"), ("6:1", "6:1"), ("8:1", "8:1"), ("12:1", "12:1"),
                  ("16:1", "16:1"), ("custom", "Custom")]),
    dict(key="canvas_width", type="int", default=600, min=16, max=4000, step=10, scope="desktop",
         label="Canvas width", description="Canvas width in design units when the aspect ratio is Custom.",
         visible_when=vis("aspect", "custom")),
    dict(key="canvas_height", type="int", default=200, min=16, max=4000, step=10, scope="desktop",
         label="Canvas height", description="Canvas height in design units when the aspect ratio is Custom.",
         visible_when=vis("aspect", "custom")),
    dict(key="orientation", type="select", default="horizontal", scope="desktop", label="Orientation",
         description="Vertical runs the bands top to bottom, for tall boxes along a screen edge. Preset aspect ratios flip to match.",
         options=[("horizontal", "Horizontal"), ("vertical", "Vertical")]),
    dict(key="spacing", type="double", default={"bar": 2.0, "desktop": 3.0}, min=0.0, max=40.0, step=0.5,
         label="Spacing", description="Gap between bars, dots or cells (rows for the meter, ring gap for rings)."),
    dict(key="bar_width", type="double", default=0.0, min=0.0, max=120.0, step=0.5, label="Bar width",
         description="Fixed width of each bar. 0 fits the bars to the available length.",
         visible_when=shapes(*WIDTH_SHAPES)),
    dict(key="roundness", type="int", default={"bar": 100, "desktop": 50}, min=0, max=100, step=5,
         label="Corner roundness (%)", description="0 is square, 100 is fully rounded (pill / circle ends).",
         visible_when=shapes(*ROUND_SHAPES)),
    dict(key="min_size", type="double", default={"bar": 2.0, "desktop": 3.0}, min=0.0, max=60.0, step=0.5,
         label="Minimum size", description="Length every element keeps at silence, so a quiet baseline stays visible. 0 lets it vanish."),

    # ── Colors ───────────────────────────────────────────────────────────
    dict(key="color_mode", type="select", default="gradient", label="Color mode",
         description="Theme colors stay in sync with your Noctalia palette.",
         options=[("solid", "Solid (color 1)"), ("gradient", "Gradient across (1 → 2 → 3)"),
                  ("level", "By level (quiet = 1, loud = 2 / 3)"), ("rainbow", "Rainbow (hue from color 1)"),
                  ("palette", "Alternate colors 1 / 2 / 3")]),
    dict(key="color_1", type="color", default="primary", label="Color 1"),
    dict(key="color_2", type="color", default="tertiary", label="Color 2",
         description="Second gradient stop; also the accent of the bloom center and pulse rings."),
    # The desktop inspector's color pickers have no "none" choice, so optional
    # colors are switched on with their own toggle.
    dict(key="use_color_3", type="bool", default=False, label="Use color 3",
         description="Add a third stop to gradients and alternating colors."),
    dict(key="color_3", type="color", default="secondary", label="Color 3",
         description="Third gradient / alternating color, when Use color 3 is on.",
         visible_when=vis("use_color_3", "true")),
    dict(key="rainbow_speed", type="int", default=0, min=-360, max=360, step=5, label="Rainbow speed (°/s)",
         description="Hue rotation of the Rainbow color mode. 0 keeps it still.",
         visible_when=vis("color_mode", "rainbow")),
    dict(key="opacity", type="double", default=1.0, min=0.05, max=1.0, step=0.05, label="Opacity"),
    dict(key="track_opacity", type="double", default=0.12, min=0.0, max=1.0, step=0.02,
         label="Track / unlit opacity",
         description="Opacity of unlit LED cells, meter segments, ring tracks, the radial base circle and bar tracks. 0 hides them."),
    dict(key="bar_tracks", type="bool", default=False, label="Show bar tracks",
         description="Draw a faint full-length track behind each bar.",
         visible_when=shapes("bars", "dots", "lollipops", "radial")),
    dict(key="glow", type="int", default=0, min=0, max=32, step=1, label="Glow",
         description="Soft glow radius behind bars and dots. Doubles the drawn elements, so keep it modest at high resolutions."),
    dict(key="glow_strength", type="double", default=0.6, min=0.05, max=1.0, step=0.05, label="Glow strength",
         advanced=True),

    # ── Peaks ────────────────────────────────────────────────────────────
    dict(key="show_peaks", type="bool", default=False, label="Show peaks",
         description="Caps that hold the recent maximum and then fall."),
    dict(key="custom_peak_color", type="bool", default=False, label="Custom peak color",
         description="Off draws peaks in each bar's own color.", visible_when=vis("show_peaks", "true")),
    dict(key="peak_color", type="color", default="on_surface", label="Peak color",
         description="Used when Custom peak color is on.", visible_when=vis("custom_peak_color", "true")),
    dict(key="peak_thickness", type="double", default=2.0, min=0.5, max=12.0, step=0.5, label="Peak thickness",
         description="Peak settings apply when Show peaks is on.", visible_when=vis("show_peaks", "true")),
    dict(key="peak_hold_ms", type="int", default=400, min=0, max=3000, step=50, label="Peak hold (ms)",
         advanced=True, visible_when=vis("show_peaks", "true")),
    dict(key="peak_gravity", type="double", default=2.5, min=0.1, max=20.0, step=0.1, label="Peak fall speed",
         description="Gravity applied to falling peaks (full heights per second²).", advanced=True,
         visible_when=vis("show_peaks", "true")),

    # ── Shape-specific ───────────────────────────────────────────────────
    dict(key="segments", type="int", default={"bar": 6, "desktop": 16}, min=1, max=64, step=1,
         label="Segments", description="LED cells per band (blocks, dot matrix) or per meter row. 1 makes the meter continuous.",
         visible_when=shapes("blocks", "dot_matrix", "meter")),
    dict(key="segment_gap", type="double", default={"bar": 1.0, "desktop": 2.0}, min=0.0, max=20.0, step=0.5,
         label="Segment gap", description="Gap between cells (and between spectrogram rows).",
         visible_when=shapes("blocks", "dot_matrix", "meter", "spectrogram")),
    dict(key="text_rows", type="int", default={"bar": 1, "desktop": 4}, min=1, max=16, step=1,
         label="Minimum text rows",
         description="Lines of characters stacked to draw taller bars. More rows are added automatically to "
                     "fill the height when the band count makes the characters small.",
         visible_when=shapes("text", "braille")),
    dict(key="text_font", type="string", default="monospace", label="Text font",
         description="Font family for the text shapes. A monospace font keeps columns aligned.",
         visible_when=shapes("text", "braille")),
    dict(key="history", type="int", default={"bar": 10, "desktop": 32}, min=2, max=96, step=1,
         label="History rows", description="Rows of past spectra kept on screen (capped at about 1400 cells).",
         visible_when=shapes("spectrogram")),
    dict(key="history_ms", type="int", default=50, min=10, max=1000, step=10, label="Scroll interval (ms)",
         description="Time between spectrogram rows.", visible_when=shapes("spectrogram"), advanced=True),
    dict(key="ring_count", type="int", default={"bar": 3, "desktop": 6}, min=1, max=24, step=1,
         label="Rings", description="Number of concentric rings; the outer ring is the bass.",
         visible_when=shapes("rings")),
    dict(key="radial_direction", type="select", default="out", label="Bar direction",
         options=[("out", "Outward"), ("in", "Inward"), ("both", "Both ways")],
         visible_when=shapes(*RADIAL_DIR)),
    dict(key="radial_inner", type="int", default=35, min=0, max=95, step=1, label="Inner radius (%)",
         description="Radius of the base circle as a share of the available radius.",
         visible_when=shapes("radial", "radial_dots", "circle_wave", "spiral", "rings")),
    dict(key="radial_arc", type="int", default=360, min=10, max=360, step=5, label="Arc (°)",
         description="How much of the circle is used; less than 360 draws a fan centered on the rotation angle.",
         visible_when=shapes("radial", "radial_dots", "circle_wave", "bloom", "rings")),
    dict(key="radial_rotation", type="int", default=0, min=-180, max=180, step=5, label="Rotation (°)",
         description="Turns the whole shape; 0 points the start (or the fan center) at 12 o'clock.",
         visible_when=shapes(*RADIAL_ALL)),
    dict(key="spin", type="double", default=0.0, min=-180.0, max=180.0, step=1.0, label="Spin (°/s)",
         description="Continuous rotation. Rings alternate direction.",
         visible_when=shapes(*RADIAL_ALL)),
    dict(key="spiral_turns", type="double", default=2.5, min=0.25, max=8.0, step=0.25, label="Spiral turns",
         visible_when=shapes("spiral")),
    dict(key="line_width", type="double", default={"bar": 1.5, "desktop": 2.5}, min=0.5, max=12.0, step=0.5,
         label="Line width", visible_when=shapes("wave", "area", "circle_wave")),
    dict(key="fill_opacity", type="double", default=0.5, min=0.0, max=1.0, step=0.05, label="Fill opacity",
         visible_when=shapes("area")),

    # ── Dynamics ─────────────────────────────────────────────────────────
    dict(key="sensitivity", type="double", default=1.0, min=0.1, max=5.0, step=0.05, label="Sensitivity",
         description="Gain applied to the spectrum before drawing."),
    dict(key="noise_floor", type="double", default=0.02, min=0.0, max=0.5, step=0.01, label="Noise floor",
         description="Levels below this are treated as silence.", advanced=True),
    dict(key="curve", type="double", default=1.0, min=0.2, max=3.0, step=0.05, label="Response curve",
         description="Below 1 lifts quiet parts, above 1 emphasises loud hits.", advanced=True),
    dict(key="tilt", type="double", default=0.0, min=-1.0, max=1.0, step=0.05, label="Treble tilt",
         description="Positive boosts highs and cuts bass; negative does the opposite.", advanced=True),
    dict(key="spread", type="double", default=0.0, min=0.0, max=0.95, step=0.05, label="Neighbour spread",
         description="Lifts each band toward its neighbours for smoother, rounder shapes (monstercat-style).",
         advanced=True),
    dict(key="attack_ms", type="int", default=0, min=0, max=1000, step=5, label="Rise smoothing (ms)",
         description="Time constant for rising levels. 0 reacts instantly.", advanced=True),
    dict(key="release_ms", type="int", default=60, min=0, max=2000, step=10, label="Fall smoothing (ms)",
         description="Time constant for falling levels. Higher values fall more slowly.", advanced=True),

    # ── Behaviour ────────────────────────────────────────────────────────
    dict(key="idle_mode", type="select", default="fade", label="When silent",
         options=[("keep", "Keep showing"), ("fade", "Fade out"), ("hide", "Hide"),
                  ("breathe", "Gentle breathing animation")]),
    dict(key="idle_opacity", type="double", default=0.35, min=0.0, max=1.0, step=0.05, label="Silent opacity",
         description="Opacity to fade to when silent behaviour is Fade out.",
         visible_when=vis("idle_mode", "fade")),
    dict(key="idle_delay_ms", type="int", default=2000, min=0, max=30000, step=250, label="Silence delay (ms)",
         description="How long the audio must stay silent before the silent behaviour starts.", advanced=True),
    dict(key="max_fps", type="int", default=60, min=10, max=240, step=5, label="Max frame rate",
         description="Upper limit on redraws per second.", advanced=True),
    dict(key="mpris_only", type="bool", default=False, label="Only while media plays",
         description="Ignore audio unless an MPRIS player is playing (skips notification sounds and calls).",
         advanced=True),
    dict(key="pause_fullscreen", type="bool", default=True, label="Pause while fullscreen",
         description="Hide and stop drawing while a fullscreen window (a game, a video) covers this output. "
                     "Needs a compositor Noctalia can watch (Umbriel, niri, Hyprland)."),

    # ── Audio source ─────────────────────────────────────────────────────
    dict(key="audio_spectrum", type="bool", default=True, scope="bar", label="Capture audio", advanced=True,
         description="Subscribe to Noctalia's PipeWire spectrum. Turning it off leaves the widget idle."),
    dict(key="cava_path", type="file", default="cava", scope="desktop", label="cava executable", advanced=True,
         description="The desktop widget runs cava for audio. A bare name is looked up in PATH."),
    dict(key="cava_method", type="select", default="pipewire", scope="desktop", label="cava input",
         advanced=True, options=[("pipewire", "PipeWire"), ("pulse", "PulseAudio")]),
    dict(key="audio_source", type="string", default="", scope="desktop", label="Audio source", advanced=True,
         description="cava source (node / monitor name). Empty uses the default output, so you see what you hear."),
    dict(key="cava_noise_reduction", type="int", default=70, min=0, max=100, step=1, scope="desktop",
         label="cava smoothing", advanced=True,
         description="cava's own noise reduction. Higher is smoother but slower."),
    dict(key="cava_autosens", type="bool", default=True, scope="desktop", label="cava auto sensitivity",
         advanced=True, description="Let cava normalise loudness automatically."),
    dict(key="low_cutoff", type="int", default=50, min=10, max=1000, step=10, scope="desktop",
         label="Lowest frequency (Hz)", advanced=True),
    dict(key="high_cutoff", type="int", default=10000, min=1000, max=22000, step=500, scope="desktop",
         label="Highest frequency (Hz)", advanced=True),
]

# ── Desktop / lock-screen settings pages ─────────────────────────────────────
# Noctalia's desktop-widget inspector lists every visible setting in one
# column that neither scrolls nor honours `advanced`, and a manifest
# `visible_when` takes a single condition. The desktop entry therefore adds a
# `settings_page` selector: every general setting is gated on its page, while
# options that only a few shapes use stay gated on `shape` and are listed at
# the end of every page. The bar widget's settings live in the scrollable
# Settings window, so it keeps the flat list (with advanced options).

PAGES = [
    ("shape", "Shape & canvas"),
    ("size", "Spacing & size"),
    ("colors", "Colors"),
    ("effects", "Peaks & glow"),
    ("response", "Response & smoothing"),
    ("silence", "Silence & frame rate"),
    ("audio", "Audio input (cava)"),
]

DESKTOP_PAGE = {
    "shape": "shape", "baseline": "shape", "frequency_layout": "shape", "audio_spectrum_bands": "shape",
    "aspect": "shape", "canvas_width": "shape", "canvas_height": "shape", "orientation": "shape",
    "spacing": "size", "bar_width": "size", "roundness": "size", "min_size": "size", "bar_tracks": "size",
    "color_mode": "colors", "color_1": "colors", "color_2": "colors", "use_color_3": "colors",
    "color_3": "colors", "rainbow_speed": "colors", "opacity": "colors", "track_opacity": "colors",
    "show_peaks": "effects", "custom_peak_color": "effects", "peak_color": "effects",
    "peak_thickness": "effects", "peak_hold_ms": "effects", "peak_gravity": "effects",
    "glow": "effects", "glow_strength": "effects",
    "sensitivity": "response", "noise_floor": "response", "curve": "response", "tilt": "response",
    "spread": "response", "attack_ms": "response", "release_ms": "response",
    "idle_mode": "silence", "idle_opacity": "silence", "idle_delay_ms": "silence", "max_fps": "silence",
    "mpris_only": "silence", "pause_fullscreen": "silence",
    "cava_path": "audio", "cava_method": "audio", "audio_source": "audio", "cava_noise_reduction": "audio",
    "cava_autosens": "audio", "low_cutoff": "audio", "high_cutoff": "audio",
}

PAGE_SETTING = dict(
    key="settings_page", type="select", default="shape", scope="desktop", label="Settings page",
    description="Which group of settings to show. Options that only apply to the selected shape "
                "(radial angles, LED segments, text rows...) are listed at the end of every page.",
    options=PAGES)

# Most plugin rows the desktop inspector may show at once (page selector +
# page + shape-specific options); Noctalia adds up to ~7 of its own
# (background section and reset). Generation fails above this.
MAX_DESKTOP_ROWS = 16


def desktop_settings():
    """Desktop entry settings in emission order, with page gating applied."""
    entries = [s for s in SETTINGS if s.get("scope", "both") in ("both", "desktop")]
    paged, gated = [], []
    for s in entries:
        page = DESKTOP_PAGE.get(s["key"])
        if page is not None:
            d = {k: v for k, v in s.items() if k not in ("visible_when", "advanced")}
            d["visible_when"] = vis("settings_page", page)
            paged.append(d)
        else:
            vw = s.get("visible_when")
            assert vw is not None and vw["key"] == "shape", (
                f"desktop setting {s['key']!r} needs a page in DESKTOP_PAGE (or a shape gate)")
            gated.append({k: v for k, v in s.items() if k != "advanced"})
    return [PAGE_SETTING] + paged + gated


def desktop_row_report():
    """Simulate the inspector's visibility rules for every shape x page."""
    settings = desktop_settings()

    def as_value(v):
        return ("true" if v else "false") if isinstance(v, bool) else str(v)

    defaults = {s["key"]: as_value(per(s["default"], "desktop")) for s in settings}
    worst = {}
    for page, _ in PAGES:
        for shape, _ in SHAPES:
            values = dict(defaults, settings_page=page, shape=shape)
            rows = sum(1 for s in settings
                       if "visible_when" not in s or values[s["visible_when"]["key"]] in s["visible_when"]["values"])
            if rows > worst.get(page, (0, ""))[0]:
                worst[page] = (rows, shape)
    return worst


HEADER = '''# Spectra - a highly customizable audio visualizer for Noctalia.
#
#   [[widget]]          bar      - bar widget fed by Noctalia's PipeWire spectrum
#   [[desktop_widget]]  desktop  - desktop / lock-screen widget fed by cava
#   [[panel]]           gallery  - every shape side by side (demo signal)
#
# Both entries share the same 20 shapes and appearance settings, configured
# per instance. GENERATED by tools/gen_manifest.py - edit that file instead.

id = "kylex/spectra"
name = "Spectra"
version = "{version}"
plugin_api = 55
author = "kylex"
license = "MIT"
dependencies = ["cava"]
tags = ["audio", "music", "bar", "desktop", "visualizer"]
icon = "chart-bar"
description = "Audio visualizer for the bar, desktop and lock screen: 20 shapes (bars, LED blocks, waves, braille, spectrogram, radial, rings, spiral...) with theme-aware colors and fine control over resolution, spacing, peaks and dynamics."
'''


def toml_value(v, typ):
    if typ == "bool":
        return "true" if v else "false"
    if typ == "double":
        return repr(float(v))
    if typ == "int":
        return str(int(v))
    return json.dumps(v, ensure_ascii=False)


def per(value, scope):
    if isinstance(value, dict):
        return value[scope]
    return value


def setting_block(s, table, scope, indent):
    pad = " " * indent
    key = s["key"]
    lines = [f"{pad}[[{table}]]", f'{pad}key = "{key}"', f'{pad}type = "{s["type"]}"',
             f'{pad}label_key = "settings.{key}.label"']
    if s.get("description"):
        lines.append(f'{pad}description_key = "settings.{key}.description"')
    lines.append(f"{pad}default = {toml_value(per(s['default'], scope), s['type'])}")
    for bound in ("min", "max", "step"):
        if bound in s:
            lines.append(f"{pad}{bound} = {toml_value(per(s[bound], scope), s['type'])}")
    if "options" in s:
        opts = ", ".join(
            f'{{ value = "{v}", label_key = "settings.{key}.options.{v}" }}' for v, _ in s["options"])
        lines.append(f"{pad}options = [{opts}]")
    if s.get("advanced"):
        lines.append(f"{pad}advanced = true")
    if "visible_when" in s:
        vw = s["visible_when"]
        vals = ", ".join(json.dumps(v) for v in vw["values"])
        lines.append(f'{pad}visible_when = {{ key = "{vw["key"]}", values = [{vals}] }}')
    return "\n".join(lines)


def build_manifest():
    out = [HEADER.format(version=VERSION)]
    out.append('[[widget]]\nid = "bar"\nentry = "bar.luau"\n')
    for s in SETTINGS:
        if s.get("scope", "both") in ("both", "bar"):
            out.append(setting_block(s, "widget.setting", "bar", 2) + "\n")
    out.append('[[desktop_widget]]\nid = "desktop"\nentry = "desktop.luau"\n')
    out.append("  # Settings are split into pages (settings_page); see tools/gen_manifest.py.\n")
    for s in desktop_settings():
        out.append(setting_block(s, "desktop_widget.setting", "desktop", 2) + "\n")
    out.append(
        "# Shape gallery: every shape animated by a demo signal.\n"
        "#   noctalia msg panel-toggle kylex/spectra:gallery\n"
        '[[panel]]\nid = "gallery"\nentry = "gallery.luau"\nwidth = 1160\nheight = 640\n'
        'placement = "floating"\nposition = "center"\n')
    return "\n".join(out)


def build_translations():
    settings = {}
    for s in [PAGE_SETTING] + SETTINGS:
        entry = {"label": s["label"]}
        if s.get("description"):
            entry["description"] = s["description"]
        if "options" in s:
            entry["options"] = {v: label for v, label in s["options"]}
        settings[s["key"]] = entry
    return {
        "desktop": {
            "cava_missing": "cava not found ({path}). Install cava or set its path in the widget settings.",
            "cava_failed": "Could not start cava. Check the log for details.",
        },
        "gallery": {
            "hint": "Demo signal, current theme colors. Pick a shape in a widget's settings.",
        },
        "settings": settings,
    }


def flat_desktop_rows():
    """Rows the inspector showed before paging (flat list, original gates)."""
    entries = [s for s in SETTINGS if s.get("scope", "both") in ("both", "desktop")]
    defaults = {s["key"]: per(s["default"], "desktop") for s in entries}
    worst = 0
    for shape, _ in SHAPES:
        values = {k: (("true" if v else "false") if isinstance(v, bool) else str(v)) for k, v in defaults.items()}
        values["shape"] = shape
        rows = sum(1 for s in entries
                   if "visible_when" not in s or values[s["visible_when"]["key"]] in s["visible_when"]["values"])
        worst = max(worst, rows)
    return worst


def main():
    report = desktop_row_report()
    print("desktop inspector rows (plugin settings, worst shape per page):")
    for page, label in PAGES:
        rows, shape = report[page]
        print(f"  {label:<24} {rows:2d}  ({shape})")
    print(f"  flat list before paging: {flat_desktop_rows()} rows")
    over = {p: r for p, r in report.items() if r[0] > MAX_DESKTOP_ROWS}
    if over:
        raise SystemExit(f"pages over MAX_DESKTOP_ROWS={MAX_DESKTOP_ROWS}: {over}")
    (ROOT / "plugin.toml").write_text(build_manifest())
    # The desktop entry finds its own widget box by matching its settings
    # against the placed instances; it may only read keys it declares.
    keys = ",\n".join(f'  "{s["key"]}"' for s in desktop_settings())
    (ROOT / "lib" / "desktop_keys.luau").write_text(
        "--!nonstrict\n-- GENERATED by tools/gen_manifest.py: setting keys declared by the desktop entry.\n"
        f"return {{\n{keys},\n}}\n")
    tr = ROOT / "translations"
    tr.mkdir(exist_ok=True)
    (tr / "en.json").write_text(json.dumps(build_translations(), indent=2, ensure_ascii=False) + "\n")
    print("wrote plugin.toml and translations/en.json")


if __name__ == "__main__":
    main()
