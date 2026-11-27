--!nonstrict
-- Logic of the desktop / lock-screen widget entry (desktop.luau wires it to
-- the globals).
--
-- Plugin desktop widgets do not get the shell's spectrum feed, so each
-- instance runs its own `cava` (raw ASCII output) through noctalia.runStream.
-- The process belongs to the widget's runtime: Noctalia kills it when the
-- widget is removed or reloaded, and on the lock screen when the session
-- unlocks. Content is drawn on a fixed design canvas that the host scales
-- into the widget's box, so sizes in settings are canvas units.
--
-- `widget` is desktopWidget (or a test double); `overrides` may replace any
-- of the noctalia functions listed in HOST_FUNCTIONS, plus `config` (for
-- noctalia.getConfig), `getSetting` and `outputName`, so lib/selftest.luau
-- can drive the entry offline.

local Engine = require("./engine.luau")
local Fullscreen = require("./fullscreen.luau")
local DESKTOP_KEYS = require("./desktop_keys.luau")

local ENTRY_TYPE = "kylex/spectra:desktop"

local M = {}

-- Must match the [[desktop_widget.setting]] defaults in plugin.toml.
M.DEFAULTS = {
  shape = "bars",
  baseline = "bottom",
  bands = 64,
  spacing = 3,
  roundness = 50,
  minSize = 3,
  segments = 16,
  segmentGap = 2,
  textRows = 4,
  history = 32,
  ringCount = 6,
  lineWidth = 2.5,
  releaseMs = 60,
}

local LONG_SIDE = 600
local ASPECTS = {
  ["1:1"] = 1,
  ["4:3"] = 4 / 3,
  ["16:9"] = 16 / 9,
  ["2:1"] = 2,
  ["3:1"] = 3,
  ["4:1"] = 4,
  ["6:1"] = 6,
  ["8:1"] = 8,
  ["12:1"] = 12,
  ["16:1"] = 16,
}

local HOST_FUNCTIONS = {
  "nowMs",
  "setUpdateInterval",
  "log",
  "tr",
  "runStream",
  "commandExists",
  "fileExists",
  "expandPath",
  "pluginDataDir",
  "readFile",
  "writeFile",
  "mediaPlayer",
}

local function shellQuote(s: string): string
  return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function hash(s: string): string
  local h1, h2 = 5381, 52711
  for i = 1, #s do
    local b = string.byte(s, i)
    h1 = (h1 * 33 + b) % 4294967296
    h2 = (h2 * 31 + b) % 4294967296
  end
  return string.format("%08x%08x", h1, h2)
end

function M.new(widget, overrides)
  local o = overrides or {}
  local host = {}
  for _, name in ipairs(HOST_FUNCTIONS) do
    host[name] = o[name] or noctalia[name]
  end
  local config = o.config or function(key)
    return noctalia.getConfig(key)
  end

  local c = Engine.readConfig(M.DEFAULTS, o.config)
  local aspect = config("aspect") or "auto"
  local customW = math.max(16, tonumber(config("canvas_width")) or 600)
  local customH = math.max(16, tonumber(config("canvas_height")) or 200)
  local vertical = config("orientation") == "vertical"
  local cavaPath = config("cava_path") or "cava"
  local cavaMethod = config("cava_method") or "pipewire"
  local audioSource = config("audio_source") or ""
  local cavaNoise = math.clamp(tonumber(config("cava_noise_reduction")) or 70, 0, 100)
  local cavaAutosens = config("cava_autosens") ~= false
  local lowCut = math.clamp(tonumber(config("low_cutoff")) or 50, 10, 1000)
  local highCut = math.clamp(tonumber(config("high_cutoff")) or 10000, 1000, 22000)
  if cavaPath == "" then
    cavaPath = "cava"
  end

  local engine = Engine.new(c)
  local self = { engine = engine, config = c }

  -- The canvas (the layout root) follows the configured shape only and never
  -- changes size while the widget lives; IPC previews keep it too.
  do
    local w, h
    if aspect == "custom" then
      w, h = customW, customH
      if vertical then
        w, h = h, w -- shapes draw in a horizontal frame; the engine turns it
      end
    else
      local ratio = ASPECTS[aspect]
      if ratio == nil then
        ratio = if engine:isRadial(c.shape) then 1 else 3
      end
      w, h = LONG_SIDE, LONG_SIDE / ratio
    end
    engine:setGeometry(w, h, vertical)
  end

  -- "Auto" fills the widget box. The script is not told its box, so find this
  -- instance among the placed Spectra widgets (desktop and lock screen) by
  -- matching its saved settings, read the box from the shell config, and
  -- mirror the host's fit: content is scaled by min(innerW / canvasW,
  -- innerH / canvasH) and centered, so the box spans innerW / scale x
  -- innerH / scale canvas units. Reading those paths with getSetting also makes
  -- the host reload this script whenever the box is resized.
  function self.locateBox()
    local getSetting = o.getSetting or noctalia.getSetting
    local myOutput = o.outputName
    if myOutput == nil and barWidget ~= nil and barWidget.outputName ~= nil then
      local ok, name = pcall(barWidget.outputName) -- reads this runtime's own output
      myOutput = if ok then name else nil
    end
    local function same(a, b)
      if type(a) == "number" and type(b) == "number" then
        return math.abs(a - b) <= 1e-6 * math.max(1, math.abs(a), math.abs(b))
      end
      return a == b
    end
    local matches = {}
    for _, section in ipairs({ "desktop_widgets", "lockscreen_widgets" }) do
      local order = getSetting(section .. ".widget_order")
      if type(order) == "table" then
        for _, id in ipairs(order) do
          if type(id) == "string" and not string.find(id, "[@.\"]") then
            local base = section .. ".widget." .. id
            if getSetting(base .. ".type") == ENTRY_TYPE then
              local inst = getSetting(base)
              local saved = if type(inst) == "table" and type(inst.settings) == "table" then inst.settings else {}
              local consistent = type(inst) == "table"
                and (myOutput == nil or inst.output == nil or inst.output == myOutput)
              if consistent then
                for _, key in ipairs(DESKTOP_KEYS) do
                  local v = saved[key]
                  if v ~= nil and not same(v, config(key)) then
                    consistent = false
                    break
                  end
                end
              end
              if consistent then
                table.insert(matches, { inst = inst, saved = saved })
              end
            end
          end
        end
      end
    end
    if #matches == 0 then
      return nil, "no matching instance"
    end
    local function boxOf(m)
      local inst, saved = m.inst, m.saved
      local bw, bh = tonumber(inst.box_width) or 0, tonumber(inst.box_height) or 0
      local bg = saved.background ~= false
      local pad = if bg then tonumber(saved.background_padding) or 10 else 0
      return bw, bh, pad
    end
    local bw, bh, pad = boxOf(matches[1])
    for i = 2, #matches do
      local w2, h2, p2 = boxOf(matches[i])
      if w2 ~= bw or h2 ~= bh or p2 ~= pad then
        return nil, "several placed widgets share these settings"
      end
    end
    if bw <= 0 or bh <= 0 then
      return nil, "box not sized yet"
    end
    local uiScale = tonumber(getSetting("accessibility.ui_scale")) or 1
    local base = math.max(0.01, uiScale)
    local px = math.floor(pad * base + 0.5)
    return math.max(1, bw - 2 * px), math.max(1, bh - 2 * px), base
  end

  if aspect == "auto" then
    local innerW, innerH, base = self.locateBox()
    if innerW ~= nil then
      local cw, ch = engine.canvasW, engine.canvasH
      local fit = math.clamp(math.min(innerW / (cw * base), innerH / (ch * base)), 0.05, 20)
      local scale = base * fit
      engine:setViewport(innerW / scale, innerH / scale)
      engine.pxPerUnit = scale
    end
  end

  local shownVisible = nil
  local function present(tree)
    if engine.visible ~= shownVisible then
      shownVisible = engine.visible
      widget.setVisible(shownVisible)
    end
    if tree ~= nil then
      widget.render(tree)
    end
  end

  -- ── cava ──────────────────────────────────────────────────────────────

  function self.cavaConfig(): string
    local source = if audioSource ~= "" then audioSource else "auto"
    return table.concat({
      "; generated by the kylex/spectra Noctalia plugin",
      "[general]",
      "bars = " .. c.count,
      "framerate = " .. math.floor(math.min(c.maxFps, 200)),
      "autosens = " .. (if cavaAutosens then 1 else 0),
      "sensitivity = 100",
      "lower_cutoff_freq = " .. math.floor(lowCut),
      "higher_cutoff_freq = " .. math.floor(math.max(highCut, lowCut * 2)),
      "sleep_timer = 0",
      "[input]",
      "method = " .. cavaMethod,
      "source = " .. source,
      "[output]",
      "method = raw",
      "raw_target = /dev/stdout",
      "data_format = ascii",
      "ascii_max_range = 1000",
      "bar_delimiter = 59",
      "frame_delimiter = 10",
      "channels = mono",
      "mono_option = average",
      "[smoothing]",
      "noise_reduction = " .. math.floor(cavaNoise),
      "monstercat = 0",
      "waves = 0",
      "",
    }, "\n")
  end

  local streaming = false
  local startedAtMs = 0
  local lastLineMs = 0
  local lastStartMs = -1e9

  -- One cava frame: "123;456;...;" with values 0..1000.
  function self.onLine(line: string)
    local now = host.nowMs()
    lastLineMs = now
    if engine.paused then
      return -- cava keeps streaming; skip the parse while fullscreen
    end
    local last = engine.lastStepMs
    if last ~= nil and now - last < (1000 / c.maxFps) * 0.85 then
      return
    end
    -- Split only: the DSP parses (and scales) each field in its own loop.
    local raw = string.split(line, ";")
    local m = #raw
    if m > 0 and raw[m] == "" then
      raw[m] = nil
      m -= 1
    end
    if m == 0 then
      return
    end
    present(engine:advance(now, raw, false, 0.001))
  end

  local function startCava()
    lastStartMs = host.nowMs()
    local isPath = string.find(cavaPath, "/", 1, true) ~= nil
    local exe = if isPath then host.expandPath(cavaPath) else cavaPath
    local exists = if isPath then host.fileExists(exe) else host.commandExists(cavaPath)
    if not exists then
      engine:setMessage(host.tr("desktop.cava_missing", { path = cavaPath }))
      return
    end
    local dir, err = host.pluginDataDir()
    if dir == nil then
      engine:setMessage("pluginDataDir: " .. tostring(err))
      return
    end
    local conf = self.cavaConfig()
    local path = dir .. "/cava-" .. hash(conf) .. ".conf"
    if host.readFile(path) ~= conf then
      local ok, werr = host.writeFile(path, conf)
      if not ok then
        engine:setMessage("cava config: " .. tostring(werr))
        return
      end
    end
    streaming = host.runStream("exec " .. shellQuote(exe) .. " -p " .. shellQuote(path) .. " 2>/dev/null", self.onLine)
    if streaming then
      startedAtMs = lastStartMs
      engine:setMessage(nil)
    else
      engine:setMessage(host.tr("desktop.cava_failed"))
    end
  end

  -- ── Ticks ─────────────────────────────────────────────────────────────

  local intervalMs = 0
  local lastMprisMs = -1e9

  local function setInterval(ms: number)
    if ms ~= intervalMs then
      intervalMs = ms
      host.setUpdateInterval(ms)
    end
  end

  function self.update()
    local now = host.nowMs()
    if c.mprisOnly and now - lastMprisMs >= 300 then
      lastMprisMs = now
      local player = host.mediaPlayer()
      engine.mprisBlocked = player == nil or player.status ~= "Playing"
    end
    local fed = streaming and now - lastLineMs < 250
    if not fed then
      -- No cava frames (missing, restarting or stalled): keep idle animations
      -- and decay going from the timer, and restart cava if it died.
      present(engine:advance(now, nil))
      if now - lastStartMs > 5000 and (not streaming or now - math.max(lastLineMs, startedAtMs) > 4000) then
        startCava()
      end
    end
    setInterval(if not fed and engine.animating then 33 else 250)
  end

  function self.onIpc(event, payload)
    local status = engine:ipc(event, payload)
    if status == nil then
      host.log("spectra desktop: unknown IPC event '" .. tostring(event) .. "'")
      return
    end
    host.log("spectra desktop: " .. status)
    present(engine:advance(host.nowMs(), nil, true))
  end

  -- ── Pause while fullscreen ─────────────────────────────────────────────

  local function outputName()
    if o.outputName ~= nil then
      return o.outputName
    end
    if widget.outputName ~= nil then
      return widget.outputName()
    end
    if barWidget ~= nil and barWidget.outputName ~= nil then
      return barWidget.outputName() -- reads this runtime's own output
    end
    return nil
  end

  function self.setPaused(paused: boolean)
    engine.paused = paused
    host.log("spectra desktop: " .. (if paused then "paused (fullscreen window)" else "resumed"))
    present(engine:advance(host.nowMs(), nil, true))
  end

  function self.start()
    startCava()
    if c.pauseFullscreen then
      self.fullscreen = Fullscreen.watch({
        subscribe = o.subscribe,
        outputName = outputName,
        onChange = self.setPaused,
        log = host.log,
      })
    end
    present(engine:advance(host.nowMs(), nil, true))
    setInterval(33)
  end

  return self
end

return M
