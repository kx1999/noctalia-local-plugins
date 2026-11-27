--!nonstrict
-- The visualizer core shared by the bar widget and the desktop widget: reads
-- the appearance settings, runs the DSP, picks colors, and turns each frame
-- into a ui tree. Entries own only the audio source and the host surface.

local Dsp = require("./dsp.luau")
local Color = require("./color.luau")
local Shapes = require("./shapes.luau")
local Canvas = require("./canvas.luau")

local Engine = {}
Engine.__index = Engine

Engine.Shapes = Shapes

local VALID = {
  shape = {},
  baseline = { bottom = true, center = true, top = true },
  frequency_layout = { auto = true, low_high = true, high_low = true, mirror_center = true, mirror_edges = true },
  color_mode = { solid = true, gradient = true, level = true, rainbow = true, palette = true },
  radial_direction = { out = true, ["in"] = true, both = true },
  idle_mode = { keep = true, fade = true, hide = true, breathe = true },
}
for _, name in ipairs(Shapes.ORDER) do
  VALID.shape[name] = true
end

-- Settings source; the gallery panel swaps in its own (it declares none).
local readSetting = function(key: string)
  return noctalia.getConfig(key)
end

local function get(key: string, default)
  local v = readSetting(key)
  if v == nil then
    return default
  end
  local kind = type(default)
  if kind == "number" then
    v = tonumber(v)
    if v == nil or v ~= v then
      return default
    end
  elseif kind == "boolean" then
    if type(v) ~= "boolean" then
      return v == "true"
    end
  elseif kind == "string" then
    if type(v) ~= "string" then
      return default
    end
  end
  return v
end

local function pick(key: string, default: string): string
  local v = get(key, default)
  if VALID[key] ~= nil and not VALID[key][v] then
    return default
  end
  return v
end

-- Read every appearance / dynamics setting shared by all entries. `d` holds
-- the entry's defaults (the bar and the desktop start from different sizes)
-- and must match the manifest defaults. `source(key)` replaces
-- noctalia.getConfig when given (keys it returns nil for use the defaults).
function Engine.readConfig(d, source)
  local previous = readSetting
  if source ~= nil then
    readSetting = source
  end
  local c = Engine.readConfigInner(d)
  readSetting = previous
  return c
end

function Engine.readConfigInner(d)
  local c = {}
  c.shape = pick("shape", d.shape or "bars")
  c.baseline = pick("baseline", d.baseline or "bottom")
  c.layout = pick("frequency_layout", "auto")
  c.count = math.clamp(math.floor(get("audio_spectrum_bands", d.bands or 32)), 2, 256)
  c.spacing = math.max(0, get("spacing", d.spacing or 2))
  c.barWidth = math.max(0, get("bar_width", 0))
  c.roundness = math.clamp(get("roundness", d.roundness or 100), 0, 100) / 100
  c.minSize = math.max(0, get("min_size", d.minSize or 2))

  c.colorMode = pick("color_mode", "gradient")
  c.color1 = get("color_1", "primary")
  c.color2 = get("color_2", "tertiary")
  -- Optional colors are opted into with toggles (the desktop editor's color
  -- pickers cannot be cleared back to "none").
  c.color3 = if get("use_color_3", false) then get("color_3", "secondary") else ""
  c.peakColor = if get("custom_peak_color", false) then get("peak_color", "on_surface") else ""
  c.rainbowSpeed = get("rainbow_speed", 0)
  c.opacity = math.clamp(get("opacity", 1), 0, 1)
  c.trackAlpha = math.clamp(get("track_opacity", 0.12), 0, 1)
  c.barTracks = get("bar_tracks", false)
  c.glow = math.clamp(get("glow", 0), 0, 48)
  c.glowStrength = math.clamp(get("glow_strength", 0.6), 0, 1)

  c.showPeaks = get("show_peaks", false)
  c.peakThickness = math.max(0.5, get("peak_thickness", 2))
  c.peakHoldMs = math.max(0, get("peak_hold_ms", 400))
  c.peakGravity = math.max(0.05, get("peak_gravity", 2.5))

  c.segments = math.clamp(math.floor(get("segments", d.segments or 12)), 1, 64)
  c.segmentGap = math.max(0, get("segment_gap", d.segmentGap or 2))
  c.textRows = math.clamp(math.floor(get("text_rows", d.textRows or 1)), 1, 16)
  c.textFont = get("text_font", "monospace")
  if c.textFont == "" then
    c.textFont = nil
  end
  c.history = math.clamp(math.floor(get("history", d.history or 24)), 2, 96)
  c.historyMs = math.clamp(get("history_ms", 50), 10, 1000)
  c.ringCount = math.clamp(math.floor(get("ring_count", d.ringCount or 6)), 1, 24)
  c.radialInner = math.clamp(get("radial_inner", 35), 0, 95) / 100
  c.radialDirection = pick("radial_direction", "out")
  c.radialArc = math.clamp(get("radial_arc", 360), 10, 360)
  c.radialRotation = get("radial_rotation", 0)
  c.spin = get("spin", 0)
  c.spiralTurns = math.clamp(get("spiral_turns", 2.5), 0.25, 8)
  c.lineWidth = math.max(0.5, get("line_width", d.lineWidth or 2))
  c.fillOpacity = math.clamp(get("fill_opacity", 0.5), 0, 1)

  c.sensitivity = math.max(0, get("sensitivity", 1))
  c.noiseFloor = math.clamp(get("noise_floor", 0.02), 0, 0.9)
  c.curve = math.clamp(get("curve", 1), 0.1, 4)
  c.tilt = math.clamp(get("tilt", 0), -1, 1)
  c.spread = math.clamp(get("spread", 0), 0, 0.95)
  c.attackMs = math.max(0, get("attack_ms", 0))
  c.releaseMs = math.max(0, get("release_ms", d.releaseMs or 60))

  c.idleMode = pick("idle_mode", "fade")
  c.idleOpacity = math.clamp(get("idle_opacity", 0.35), 0, 1)
  c.idleDelayMs = math.max(0, get("idle_delay_ms", 2000))
  c.maxFps = math.clamp(get("max_fps", 60), 5, 240)
  c.mprisOnly = get("mpris_only", false)
  c.pauseFullscreen = get("pause_fullscreen", true)
  return c
end

function Engine.new(c)
  local self = setmetatable({}, Engine)
  self.c = c
  self.override = nil
  self.demo = false
  self.message = nil
  self.mprisBlocked = false
  self.paused = false -- a fullscreen window covers the widget's output
  self.dsp = Dsp.new()
  self.pal = Color.newPalette({
    mode = c.colorMode,
    color1 = c.color1,
    color2 = c.color2,
    color3 = c.color3,
    peak = c.peakColor,
    alpha = c.opacity,
    trackAlpha = c.trackAlpha,
    rainbowSpeed = c.rainbowSpeed,
  })
  self.ctx = {}
  self.shapeState = {}
  self.synth = {}
  self.opacity = nil
  self.visible = true
  self.animating = true
  self.renderedStill = false
  self.t0 = noctalia.nowMs()
  self.lastPaletteMs = self.t0
  self:setGeometry(600, 200, false)
  self:configureDsp()
  return self
end

function Engine:shape(): string
  return self.override or self.c.shape
end

function Engine:isRadial(name: string?): boolean
  return Shapes.RADIAL[name or self:shape()] == true
end

-- frameW x frameH is the horizontal shape frame; vertical turns it 90°.
function Engine:setGeometry(frameW: number, frameH: number, vertical: boolean)
  self.frameW = math.max(1, frameW)
  self.frameH = math.max(1, frameH)
  self.vertical = vertical
  if vertical then
    self.canvasW, self.canvasH = self.frameH, self.frameW
  else
    self.canvasW, self.canvasH = self.frameW, self.frameH
  end
  self.viewW, self.viewH = nil, nil
  self.renderedStill = false
end

-- The area actually visible around the canvas, in canvas units (centered on
-- it). The canvas is the fixed-size layout root the host fits into the widget
-- box; drawing over the whole viewport fills the box edge to edge without
-- ever changing the root's size (the host remembers the largest root size it
-- has seen, so a root that changed size would stop fitting).
function Engine:setViewport(viewW: number?, viewH: number?)
  if viewW ~= nil and viewH ~= nil and viewW > 0 and viewH > 0 then
    self.viewW, self.viewH = viewW, viewH
  else
    self.viewW, self.viewH = nil, nil
  end
  self.renderedStill = false
end

function Engine:configureDsp()
  local c = self.c
  local name = self:shape()
  local layout = c.layout
  if Shapes.FIXED_LAYOUT[name] then
    layout = "low_high"
  elseif layout == "auto" then
    layout = if Shapes.RADIAL[name] then "mirror_center" else "low_high"
  end
  self.dsp:configure({
    count = c.count,
    layout = layout,
    gain = c.sensitivity,
    floor = c.noiseFloor,
    curve = c.curve,
    tilt = c.tilt,
    spread = c.spread,
    attackMs = c.attackMs,
    releaseMs = c.releaseMs,
    peakHoldMs = c.peakHoldMs,
    peakGravity = c.peakGravity,
    idleDelayMs = c.idleDelayMs,
  })
  self.renderedStill = false
end

function Engine:setMessage(text: string?)
  if text ~= self.message then
    self.message = text
    self.renderedStill = false
  end
end

-- Advance one frame. `raw` is the latest source spectrum (nil = silence /
-- no new data): numbers or numeric strings, each times `scale` (default 1)
-- in 0..1. Returns a ui tree when something needs drawing, else nil.
-- `force` bypasses the frame-rate throttle (used after IPC / config changes).
function Engine:advance(now: number, raw, force: boolean?, scale: number?)
  local c = self.c
  -- Paused while fullscreen: hide and draw nothing until the window leaves.
  if self.paused then
    self.visible = false
    self.animating = false
    self.renderedStill = false
    self.lastStepMs = nil
    return nil
  end
  local last = self.lastStepMs
  if not force and last ~= nil and now - last < (1000 / c.maxFps) * 0.85 then
    return nil
  end
  local dt = if last ~= nil then math.clamp(now - last, 0, 250) else 16
  self.lastStepMs = now
  local t = (now - self.t0) / 1000

  if now - self.lastPaletteMs >= 1000 then
    self.lastPaletteMs = now
    if self.pal:refresh() then
      self.renderedStill = false -- the theme changed
    end
  end

  local dsp = self.dsp
  if self.mprisBlocked then
    raw = nil
  end
  local synthetic = false
  if self.demo or (dsp.idle and c.idleMode == "breathe") then
    -- Synthetic frames: watch the real source separately.
    dsp:observe(raw, dt, scale)
    if self.demo then
      dsp:step(Dsp.demo(48, t, self.synth), dt)
      synthetic = true
    elseif dsp.idle then
      dsp:step(Dsp.breathe(48, t, self.synth), dt)
      synthetic = true
    else
      dsp:step(raw, dt, scale)
    end
  else
    -- step() measures the source level on its way through.
    dsp:observeEnergy(dsp:step(raw, dt, scale), dt)
  end
  local idle = dsp.idle and not self.demo

  local target = 1
  if idle then
    if c.idleMode == "fade" then
      target = c.idleOpacity
    elseif c.idleMode == "hide" then
      target = 0
    end
  end
  local prevOpacity = self.opacity
  if self.opacity == nil then
    self.opacity = target
  else
    self.opacity += (target - self.opacity) * (1 - math.exp(-dt / 350))
    if math.abs(self.opacity - target) < 0.004 then
      self.opacity = target
    end
  end
  self.visible = not (c.idleMode == "hide" and idle and self.opacity <= 0.01)

  local timeDriven = c.spin ~= 0 or (c.colorMode == "rainbow" and c.rainbowSpeed ~= 0)
  local animating = synthetic or timeDriven or self.opacity ~= target or not dsp:settled()
  self.animating = animating
  if not animating and self.renderedStill then
    return nil
  end
  self.renderedStill = not animating
  if not self.visible then
    return nil
  end
  return self:render(t, prevOpacity ~= self.opacity)
end

function Engine:render(t: number, opacityChanged: boolean?)
  local c = self.c
  if self.message ~= nil then
    return Canvas.message(self.canvasW, self.canvasH, self.message)
  end
  local name = self:shape()
  local fn = Shapes[name] or Shapes.bars
  local radial = Shapes.RADIAL[name] == true
  local dsp = self.dsp
  local ctx = self.ctx
  local vw, vh = self.viewW or self.canvasW, self.viewH or self.canvasH
  local vertical = self.vertical and not radial
  if vertical then
    ctx.W, ctx.H = vh, vw -- shapes draw in the horizontal frame
  else
    ctx.W, ctx.H = vw, vh
  end
  ctx.n = dsp.n
  ctx.values = dsp.values
  ctx.peaks = dsp.peaks
  ctx.spectrum = dsp.spectrum
  ctx.spectrumPeaks = dsp.peakLevel
  ctx.pal = self.pal
  ctx.c = c
  -- Screen pixels per canvas unit (known on the desktop once the box is
  -- found; an estimate elsewhere), so shapes can size detail to the screen.
  ctx.pxPerUnit = self.pxPerUnit or 1.5
  ctx.pxPerUnitKnown = self.pxPerUnit ~= nil
  ctx.t = t
  ctx.state = self.shapeState
  ctx.out = {}
  ctx.unchanged = false
  self.pal:setTime(t)
  fn(ctx)
  if ctx.unchanged and not opacityChanged and self.lastTree ~= nil then
    return nil
  end
  local tree = Canvas.compose(self.canvasW, self.canvasH, ctx.out, {
    key = if vertical then "canvas:" .. name .. ":v" else "canvas:" .. name,
    vertical = vertical,
    frameH = ctx.H,
    offsetX = (vw - self.canvasW) / 2,
    offsetY = (vh - self.canvasH) / 2,
    glow = c.glow,
    glowStrength = c.glowStrength,
    opacity = self.opacity or 1,
  })
  self.lastTree = tree
  return tree
end

-- Runtime-only overrides over IPC (not saved to the settings):
--   shape <name> | next | prev | demo [on|off] | reset | info
-- Returns a short status line for the log.
function Engine:ipc(event: string, payload: string?): string?
  payload = if payload then noctalia.string.trim(payload) else ""
  local order = Shapes.ORDER
  local function setShape(name)
    self.override = if name == self.c.shape then nil else name
    self.shapeState = {}
    self:configureDsp()
  end
  if event == "shape" then
    if not VALID.shape[payload] then
      return "unknown shape '" .. payload .. "'; one of: " .. table.concat(order, ", ")
    end
    setShape(payload)
  elseif event == "next" or event == "prev" then
    local cur = table.find(order, self:shape()) or 1
    local step = if event == "next" then 1 else -1
    setShape(order[((cur - 1 + step) % #order) + 1])
  elseif event == "demo" then
    if payload == "on" then
      self.demo = true
    elseif payload == "off" then
      self.demo = false
    else
      self.demo = not self.demo
    end
  elseif event == "reset" then
    self.demo = false
    setShape(self.c.shape)
  elseif event ~= "info" then
    return nil
  end
  self.renderedStill = false
  return string.format(
    "shape=%s demo=%s bands=%d analysis=%d idle=%s canvas=%gx%g view=%s px/unit=%.3f",
    self:shape(),
    tostring(self.demo),
    self.dsp.n,
    self.dsp.na,
    tostring(self.dsp.idle),
    self.canvasW,
    self.canvasH,
    if self.viewW then string.format("%.2fx%.2f", self.viewW, self.viewH) else "none",
    self.pxPerUnit or 0
  )
end

return Engine
