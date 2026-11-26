--!nonstrict
-- Logic of the bar widget entry (bar.luau wires it to the globals).
--
-- `widget` is barWidget (or a test double); `overrides` may replace nowMs,
-- setUpdateInterval, log and config (for noctalia.getConfig), so
-- lib/selftest.luau can drive the entry offline.

local Engine = require("./engine.luau")
local Fullscreen = require("./fullscreen.luau")

local M = {}

-- Must match the [[widget.setting]] defaults in plugin.toml.
M.DEFAULTS = {
  shape = "bars",
  baseline = "bottom",
  bands = 24,
  spacing = 2,
  roundness = 100,
  minSize = 2,
  segments = 6,
  segmentGap = 1,
  textRows = 1,
  history = 10,
  ringCount = 3,
  lineWidth = 1.5,
  releaseMs = 60,
}

function M.new(widget, overrides)
  local o = overrides or {}
  local host = {
    nowMs = o.nowMs or noctalia.nowMs,
    setUpdateInterval = o.setUpdateInterval or noctalia.setUpdateInterval,
    log = o.log or noctalia.log,
  }
  local config = o.config or function(key)
    return noctalia.getConfig(key)
  end

  local c = Engine.readConfig(M.DEFAULTS, o.config)
  local captureOn = config("audio_spectrum") ~= false
  local length = math.max(8, tonumber(config("length")) or 140)
  local thickness = math.max(4, tonumber(config("thickness")) or 20)

  local engine = Engine.new(c)
  local shownVisible = true
  local lastSourceMs = 0
  local intervalMs = 0
  local geometryKey = ""
  local self = { engine = engine, config = c }

  local function applyGeometry()
    local vertical = widget.isVertical()
    local radial = engine:isRadial()
    local key = tostring(vertical) .. tostring(radial)
    if key == geometryKey then
      return
    end
    geometryKey = key
    if radial then
      -- Circles get a square tile the size of the bar's thickness.
      engine:setGeometry(thickness, thickness, false)
    else
      engine:setGeometry(length, thickness, vertical)
    end
  end

  local function setInterval(ms: number)
    if ms ~= intervalMs then
      intervalMs = ms
      host.setUpdateInterval(ms)
    end
  end

  local function present(tree)
    if engine.visible ~= shownVisible then
      shownVisible = engine.visible
      widget.setVisible(shownVisible)
    end
    if tree ~= nil then
      widget.render(tree)
    end
    -- Tick fast only while something is still moving (decay, fades, demo).
    setInterval(if engine.animating then 33 else 500)
  end

  local function parseCsv(csv: string)
    local out = {}
    local i = 0
    for part in string.gmatch(csv, "[^,]+") do
      i += 1
      out[i] = tonumber(part) or 0
    end
    return out
  end

  -- Host spectrum frame: valuesCsv "0.1200,0.5000,..." (low -> high),
  -- stateCsv "<audio active>,<mpris playing>" as 0/1.
  function self.onAudioSpectrum(valuesCsv, stateCsv)
    local now = host.nowMs()
    lastSourceMs = now
    if engine.paused then
      return -- hidden while a fullscreen window covers this output
    end
    -- Drop frames beyond max_fps before paying for the parse.
    local last = engine.lastStepMs
    if last ~= nil and now - last < (1000 / c.maxFps) * 0.85 then
      return
    end
    local state = stateCsv or ""
    local active = string.sub(state, 1, 1) == "1"
    local playing = string.sub(state, 3, 3) == "1"
    engine.mprisBlocked = c.mprisOnly and not playing
    local raw = if active then parseCsv(valuesCsv or "") else nil
    applyGeometry()
    present(engine:advance(now, raw))
  end

  function self.update()
    local now = host.nowMs()
    applyGeometry()
    -- The spectrum stops sending frames when audio goes quiet; keep animating
    -- the decay / fade / demo from the timer until everything settles.
    if now - lastSourceMs > 120 then
      present(engine:advance(now, nil))
    end
  end

  function self.onIpc(event, payload)
    local status = engine:ipc(event, payload)
    if status == nil then
      host.log("spectra bar: unknown IPC event '" .. tostring(event) .. "'")
      return
    end
    host.log("spectra bar: " .. status)
    geometryKey = ""
    applyGeometry()
    present(engine:advance(host.nowMs(), nil, true))
  end

  function self.setPaused(paused: boolean)
    engine.paused = paused
    host.log("spectra bar: " .. (if paused then "paused (fullscreen window)" else "resumed"))
    present(engine:advance(host.nowMs(), nil, true))
  end

  function self.start()
    if widget.clearTooltip then
      widget.clearTooltip()
    end
    applyGeometry()
    if not captureOn then
      host.log("spectra bar: audio_spectrum is off; the widget will stay idle")
    end
    if c.pauseFullscreen then
      self.fullscreen = Fullscreen.watch({
        subscribe = o.subscribe,
        outputName = function()
          if o.outputName ~= nil then
            return o.outputName
          end
          if widget.outputName ~= nil then
            return widget.outputName()
          end
          return nil
        end,
        onChange = self.setPaused,
        log = host.log,
      })
    end
    present(engine:advance(host.nowMs(), nil, true))
  end

  return self
end

return M
