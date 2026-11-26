--!nonstrict
-- Spectra shape gallery: every shape side by side, animated by a built-in
-- demo signal and colored with the current theme. Pick one, then set it in a
-- widget's settings.
--
--   noctalia msg panel-toggle kylex/spectra:gallery

local Engine = require("./lib/engine.luau")
local Shapes = Engine.Shapes

local COLUMNS = 5
local TILE_W, TILE_H = 196, 84
local FRAME_MS = 50

-- Per-shape preview tweaks on top of the defaults.
local TWEAKS = {
  bars = { show_peaks = true },
  blocks = { segments = 10 },
  dot_matrix = { segments = 8 },
  peaks = { show_peaks = true },
  text = { text_rows = 3 },
  braille = { text_rows = 2 },
  spectrogram = { history = 18 },
  meter = { segments = 14 },
  radial = { radial_inner = 40 },
  radial_dots = { radial_inner = 40 },
  circle_wave = { radial_inner = 45 },
  rings = { ring_count = 5, radial_inner = 20 },
}

local BASE = {
  shape = "bars",
  bands = 24,
  spacing = 2,
  roundness = 60,
  minSize = 2,
  segments = 10,
  segmentGap = 1.5,
  textRows = 2,
  history = 16,
  ringCount = 5,
  lineWidth = 2,
  releaseMs = 60,
}

local engines = {}
for _, name in ipairs(Shapes.ORDER) do
  local tweak = TWEAKS[name] or {}
  local c = Engine.readConfig(BASE, function(key)
    if key == "shape" then
      return name
    end
    return tweak[key]
  end)
  local e = Engine.new(c)
  e.demo = true
  if Shapes.RADIAL[name] then
    e:setGeometry(TILE_H, TILE_H, false)
  else
    e:setGeometry(TILE_W, TILE_H, false)
  end
  table.insert(engines, { name = name, engine = e, label = noctalia.tr("settings.shape.options." .. name) })
end

local sinceMs = 0
-- Engines rendered at least once. A cold engine builds its caches on its
-- first frame, so they warm up a few per tick to keep each callback short.
local warm = 0
local WARM_STEP = 4

local function render()
  local now = noctalia.nowMs()
  local rows = {}
  local row = nil
  local limit = math.min(#engines, warm + WARM_STEP)
  for i, item in ipairs(engines) do
    local tree = item.engine.lastTree
    if i <= limit then
      tree = item.engine:advance(now, nil, true) or tree
    end
    if tree == nil then
      tree = ui.box({ key = "wait", width = 4, height = 4 })
    end
    if (i - 1) % COLUMNS == 0 then
      row = {}
      table.insert(rows, ui.row({ key = "row" .. #rows + 1, gap = 12, align = "start" }, row))
    end
    table.insert(
      row,
      ui.column({
        key = item.name,
        width = TILE_W + 16,
        gap = 6,
        padding = 8,
        align = "center",
        fill = "surface_container/0.6",
        radius = 12,
      }, {
        ui.row({ key = "stage", width = TILE_W, height = TILE_H, align = "center", justify = "center" }, { tree }),
        ui.label({ key = "name", text = item.label, fontSize = 11, color = "on_surface_variant" }),
      })
    )
  end
  panel.render(ui.column({ gap = 12, padding = 4 }, {
    ui.row({ key = "head", align = "center", gap = 8 }, {
      ui.glyph({ name = "chart-bar", size = 18, color = "primary" }),
      ui.label({ text = "Spectra", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.label({ text = noctalia.tr("gallery.hint"), fontSize = 11, color = "on_surface_variant" }),
      ui.button({ glyph = "x", variant = "ghost", onClick = function()
        panel.close()
      end }),
    }),
    ui.column({ key = "grid", gap = 12 }, rows),
  }))
  warm = limit
end

function onOpen()
  sinceMs = 0
  render()
  panel.setNeedsFrameTick(true)
end

function onClose()
  panel.setNeedsFrameTick(false)
end

local Selftest = require("./lib/selftest.luau")
local runner = nil
local entryTester = nil

function onFrameTick(deltaMs)
  if runner ~= nil then
    return
  end
  sinceMs += tonumber(deltaMs) or 16
  if sinceMs >= FRAME_MS then
    sinceMs = 0
    render()
  end
end

-- The self-test runs in slices (each well inside the callback budget): one per
-- `selftest-step` IPC call, and one per second tick as a fallback. Frame ticks
-- are not used because they stop while the output is off.
local function stepSelftest()
  if runner ~= nil and runner.step(8) then
    runner = nil
    panel.setWantsSecondTicks(false)
  end
end

function update()
  stepSelftest()
end

-- noctalia msg plugin kylex/spectra:gallery all selftest        (panel open)
-- noctalia msg plugin kylex/spectra:gallery all selftest-step   (repeat)
function onIpc(event, payload)
  if event == "selftest" then
    noctalia.log("spectra selftest: starting")
    runner = Selftest.runner()
    panel.setWantsSecondTicks(true)
    stepSelftest()
  elseif event == "selftest-step" then
    stepSelftest()
  elseif event == "entrytest" then
    entryTester = Selftest.entryTests(function(msg)
      noctalia.log(msg)
    end)
    noctalia.log("spectra entrytest: starting")
  elseif event == "entrytest-step" then
    if entryTester ~= nil then
      local ok, result = pcall(entryTester)
      if not ok then
        noctalia.log("spectra entrytest ERROR: " .. tostring(result))
        entryTester = nil
      elseif result == true then
        entryTester = nil
      end
    end
  elseif event == "time" then
    -- One gallery frame (warms up a batch of engines when cold).
    local c0 = os.clock()
    render()
    noctalia.log(string.format("spectra gallery frame: %.2f ms (warm %d/%d)", (os.clock() - c0) * 1000, warm, #engines))
  elseif event == "bench" then
    Selftest.bench(payload, function(tree)
      panel.render(tree)
    end)
  end
end
