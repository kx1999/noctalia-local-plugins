--!nonstrict
-- Geometry self-test, run from the gallery panel:
--   noctalia msg plugin kylex/spectra:gallery all selftest
-- Renders every shape across baselines, orientations, band counts, peaks,
-- glow and radial options at silence, full scale and a demo signal, then
-- checks that every placed element has finite props, a positive size, and
-- (after rotation and scale) stays inside its canvas. Results go to the log.

local Engine = require("./engine.luau")
local Dsp = require("./dsp.luau")

-- Entries under test must not open real compositor subscriptions.
local function noSubscribe()
  return nil
end
local Shapes = Engine.Shapes

local M = {}

local BASE = {
  shape = "bars",
  bands = 24,
  spacing = 2,
  roundness = 60,
  minSize = 2,
  segments = 12,
  segmentGap = 1.5,
  textRows = 2,
  history = 12,
  ringCount = 5,
  lineWidth = 2,
  releaseMs = 60,
}

function M.cases()
  local list = {}
  for _, shape in ipairs(Shapes.ORDER) do
    local radial = Shapes.RADIAL[shape] == true
    local function add(o)
      o.shape = shape
      table.insert(list, o)
    end
    for _, bands in ipairs({ 5, 48 }) do
      for _, fill in ipairs({ 0, 1, "demo" }) do
        local peaks = fill ~= 0
        if radial then
          for _, dir in ipairs({ "out", "in", "both" }) do
            for _, arc in ipairs({ 360, 180 }) do
              for _, inner in ipairs({ 0, 35, 90 }) do
                add({
                  bands = bands,
                  fill = fill,
                  w = 220,
                  h = 220,
                  vertical = false,
                  over = {
                    radial_direction = dir,
                    radial_arc = arc,
                    radial_inner = inner,
                    show_peaks = peaks,
                    glow = if peaks then 4 else 0,
                    spin = 30,
                  },
                })
              end
            end
          end
          -- Radial shapes inside a thin bar-sized (non-square) canvas.
          add({ bands = bands, fill = fill, w = 140, h = 20, vertical = false, over = { show_peaks = peaks } })
          -- Desktop "fill the box": a square root inside wider / taller boxes.
          for _, view in ipairs({ { 1200, 600 }, { 600, 900 } }) do
            add({ bands = bands, fill = fill, w = 600, h = 600, vertical = false, view = view, over = { show_peaks = peaks } })
          end
        else
          for _, base in ipairs({ "bottom", "center", "top" }) do
            for _, vertical in ipairs({ false, true }) do
              add({
                bands = bands,
                fill = fill,
                w = 300,
                h = 100,
                vertical = vertical,
                over = { baseline = base, show_peaks = peaks, glow = if peaks then 4 else 0 },
              })
            end
            -- A bar-sized canvas with a fixed, overflowing bar width.
            add({
              bands = bands,
              fill = fill,
              w = 140,
              h = 20,
              vertical = false,
              over = { baseline = base, show_peaks = peaks, bar_width = 9, frequency_layout = "mirror_center" },
            })
            -- Desktop "fill the box": the 3:1 root inside wider / taller boxes,
            -- horizontal and vertical (views are of the canvas as drawn).
            for _, v in ipairs({
              { false, { 760, 200 } },
              { false, { 600, 450 } },
              { true, { 260, 600 } },
              { true, { 200, 900 } },
            }) do
              add({
                bands = bands,
                fill = fill,
                w = 600,
                h = 200,
                vertical = v[1],
                view = v[2],
                over = { baseline = base, show_peaks = peaks, glow = if peaks then 4 else 0 },
              })
            end
          end
        end
      end
    end
  end
  -- Curves in every color mode (tiling differs per mode), thin and thick
  -- lines, at the desktop's real px / unit and at an unknown one.
  for _, shape in ipairs({ "wave", "area" }) do
    for _, mode in ipairs({ "level", "solid", "gradient", "palette", "rainbow" }) do
      for _, base in ipairs({ "bottom", "center", "top" }) do
        for _, lw in ipairs({ 0.5, 6 }) do
          for _, bands in ipairs({ 128, 7 }) do
            table.insert(list, {
              shape = shape,
              bands = bands,
              fill = "demo",
              w = 600,
              h = 200,
              vertical = base == "top" and lw > 1,
              view = { 711.11, 200 },
              ppu = if bands == 128 then 7.2 else nil,
              over = {
                color_mode = mode,
                baseline = base,
                line_width = lw,
                show_peaks = true,
                use_color_3 = true,
                opacity = 0.5,
                fill_opacity = 0.25,
              },
            })
          end
        end
      end
    end
  end
  return list
end

local function finite(x)
  return x == x and x ~= math.huge and x ~= -math.huge
end

local NUMERIC = { "translateX", "translateY", "width", "height", "rotation", "scale", "radius", "progress", "thickness" }

-- Drawable area of an engine in root coordinates: the canvas, or the
-- viewport centered on it.
local function areaOf(e)
  local ox = ((e.viewW or e.canvasW) - e.canvasW) / 2
  local oy = ((e.viewH or e.canvasH) - e.canvasH) / 2
  return -ox, -oy, e.canvasW + ox, e.canvasH + oy
end

-- Walk a ui tree; `fail(msg)` reports problems. Returns the node count.
-- Placed primitives (nodes with a translate) are checked as a whole; their
-- own children (grid cells) are flex-laid out and not walked. Elements must
-- stay inside [X0, X1] x [Y0, Y1].
local function check(tree, X0, Y0, X1, Y1, fail)
  local count = 0
  local tol = 1.5
  local function walk(node)
    count += 1
    local p = node.props or {}
    for _, k in ipairs(NUMERIC) do
      local v = p[k]
      if v ~= nil and (type(v) ~= "number" or not finite(v)) then
        fail(string.format("%s.%s is %s", tostring(p.key), k, tostring(v)))
      end
    end
    if p.translateX ~= nil then
      local w, h = p.width, p.height
      if w == nil or h == nil or w <= 0 or h <= 0 then
        fail(string.format("%s has size %s x %s", tostring(p.key), tostring(w), tostring(h)))
      else
        local s = p.scale or 1
        -- Circles (rings) look the same at any rotation.
        local rot = if node.type == "ring" then 0 else math.rad(p.rotation or 0)
        local hw, hh = w * s / 2, h * s / 2
        local ex = math.abs(hw * math.cos(rot)) + math.abs(hh * math.sin(rot))
        local ey = math.abs(hw * math.sin(rot)) + math.abs(hh * math.cos(rot))
        local cx, cy = p.translateX + w / 2, p.translateY + h / 2
        if cx - ex < X0 - tol or cy - ey < Y0 - tol or cx + ex > X1 + tol or cy + ey > Y1 + tol then
          fail(
            string.format(
              "%s out of area [%.1f,%.1f]-[%.1f,%.1f]: [%.1f,%.1f]-[%.1f,%.1f]",
              tostring(p.key),
              X0,
              Y0,
              X1,
              Y1,
              cx - ex,
              cy - ey,
              cx + ex,
              cy + ey
            )
          )
        end
      end
      return
    end
    -- Placement relies on every child starting at the container's origin
    -- (zero-height slots, or runs whose gap cancels their common size).
    local kids = node.children or {}
    if #kids > 1 and (node.type == "row" or node.type == "column") then
      local mainKey = if node.type == "row" then "width" else "height"
      local gap = p.gap or 0
      local cursor = 0
      for i, child in ipairs(kids) do
        if math.abs(cursor) > 0.05 then
          fail(string.format("%s child %d laid out at %.4f, not the origin", tostring(p.key), i, cursor))
          break
        end
        local size = (child.props or {})[mainKey]
        if size == nil then
          cursor = math.huge
        else
          cursor += size + gap
        end
      end
    end
    for _, child in ipairs(kids) do
      walk(child)
    end
  end
  walk(tree)
  return count
end

-- Run one case; returns (ok, nodeCount, messages).
function M.run(case)
  local overrides = case.over or {}
  local c = Engine.readConfig(BASE, function(key)
    if key == "shape" then
      return case.shape
    elseif key == "audio_spectrum_bands" then
      return case.bands
    end
    return overrides[key]
  end)
  local e = Engine.new(c)
  if Shapes.RADIAL[case.shape] and case.w == case.h then
    e:setGeometry(case.w, case.h, false)
  else
    e:setGeometry(case.w, case.h, case.vertical)
  end
  if case.view ~= nil then
    e:setViewport(case.view[1], case.view[2])
  end
  if case.ppu ~= nil then
    e.pxPerUnit = case.ppu
  end
  local dsp = e.dsp
  if case.fill == "demo" then
    local raw = Dsp.demo(48, 1.37)
    for _ = 1, 6 do
      dsp:step(raw, 16)
    end
  else
    for i = 1, dsp.na do
      dsp.spectrum[i] = case.fill
      dsp.peakLevel[i] = case.fill
    end
    dsp:arrange()
  end
  -- Two renders so history-based shapes (spectrogram) fill a row or two.
  e.ctx.debug = {}
  e:render(0.5)
  local tree = e:render(1.0) or e.lastTree
  local msgs = {}
  local function fail(m)
    if #msgs < 3 then
      table.insert(msgs, m)
    end
  end
  if tree == nil then
    fail("no tree")
    return false, 0, msgs
  end
  local x0, y0, x1, y1 = areaOf(e)
  local n = check(tree, x0, y0, x1, y1, fail)
  -- Area / wave tiles. Each clipped graph's plot range must be exactly the
  -- visible height (the shader's padding compensated). Each strip's graph
  -- must hold exactly the samples it reads, placed so it draws the full
  -- curve, and the strip's tiles must cover every pixel the shader can
  -- paint there: the line (both series) with its anti-aliasing, and the fill
  -- below it. The curve is evaluated here the way the shader does.
  if case.shape == "area" or case.shape == "wave" then
    local ctx = e.ctx
    local gh0 = if e.c.baseline == "center" then ctx.H / 2 else ctx.H
    local lw = math.max(0.5, e.c.lineWidth)
    local nb = e.dsp.n
    local tiles = {}
    for _, p in ipairs(ctx.out) do
      local col = p.node
      local d = p.dbg
      if p.kind == "node" and col ~= nil and col.props.clip and d ~= nil then
        local hd = ctx.debug[d.half]
        local g = col.children[1].children[1].props
        local pad = Shapes.graphPad(g.height * ctx.pxPerUnit, lw * ctx.pxPerUnit)
        local plot = g.height * (1 - 2 * pad)
        if math.abs(plot - gh0) > 0.05 then
          fail(string.format("%s: plot range %.2f, visible %.2f", p.key, plot, gh0))
          break
        end
        local top = g.translateY + pad * g.height -- = -(tile offset), <= 0
        if math.abs(top + d.ly) > 0.01 or d.ly < -0.01 or d.ly + d.th > gh0 + 0.01 then
          fail(string.format("%s: plot top at %.2f for a tile at %.2f..%.2f", p.key, top, d.ly, d.ly + d.th))
          break
        end
        local m = d.kHi - d.kLo + 1
        local sp = hd.spacing
        if
          #g.values ~= m
          or math.abs(g.width - (m - 3) * sp) > 0.01
          or math.abs(g.translateX - (d.kLo * sp - d.x0)) > 0.01
          or math.abs(p.h - d.th) > 0.01
        then
          fail(string.format("%s: window %d..%d: %d samples, graph width %.2f at %.2f", p.key, d.kLo, d.kHi, #g.values, g.width, g.translateX))
          break
        end
        for i = 1, m do
          if g.values[i] ~= hd.vals[d.kLo + i] or (hd.pks ~= nil and g.values2[i] ~= hd.pks[d.kLo + i]) then
            fail(string.format("%s: sample %d differs from the full series", p.key, i))
            break
          end
        end
        if math.abs(p.w - (d.x1 - d.x0)) > 0.01 then
          fail(string.format("%s: tile width %.2f for x %.2f..%.2f", p.key, p.w, d.x0, d.x1))
          break
        end
        local list = tiles[d.half]
        if list == nil then
          list = {}
          tiles[d.half] = list
        end
        table.insert(list, d)
      end
    end
    -- The shader's curve: cubic Hermite over the texture (series + lead),
    -- fetches clamped to it. `tex` is 1-based (tex[1] = texture index 0).
    local function texOf(o)
      local count = nb + 3
      local tex = table.move(o, 1, count, 1, table.create(count + 1))
      tex[count + 1] = math.clamp(o[count] + (o[count] - o[count - 1]) * 0.5, 0, 1)
      return tex
    end
    local function curveAt(tex, di)
      local top = nb + 4
      local i = math.floor(di)
      local tt = di - i
      local y0 = tex[math.clamp(i, 1, top)]
      local y1 = tex[math.clamp(i + 1, 1, top)]
      local y2 = tex[math.clamp(i + 2, 1, top)]
      local y3 = tex[math.clamp(i + 3, 1, top)]
      local m1, m2 = (y2 - y0) * 0.25, (y3 - y1) * 0.25
      local t2 = tt * tt
      local t3 = t2 * tt
      return (2 * t3 - 3 * t2 + 1) * y1 + (t3 - 2 * t2 + tt) * m1 + (-2 * t3 + 3 * t2) * y2 + (t3 - t2) * m2
    end
    for half, hd in pairs(ctx.debug) do
      if type(hd) ~= "table" or hd.strips == nil then
        continue
      end
      local gh, sp = hd.gh, hd.spacing
      local texes = { texOf(hd.vals) }
      if hd.pks ~= nil then
        texes[2] = texOf(hd.pks)
      end
      local px = 1 / hd.ppu
      local hw = lw / 2 + 1.42 * px -- line half width plus anti-aliasing
      local list = tiles[half] or {}
      -- Every tile's window must hold every sample its pixels read.
      for _, d in ipairs(list) do
        for _, x in ipairs({ d.x0 - 2 * px, d.x1 + 2 * px }) do
          local di = 3 + math.clamp(x, 0, hd.gw) / sp
          if (d.kLo > 0 and math.floor(di) - 1 < d.kLo) or (d.kHi < nb + 2 and math.floor(di) + 2 > d.kHi) then
            fail(string.format("%s: x=%.2f (index %.2f) outside window %d..%d", half, x, di, d.kLo, d.kHi))
            break
          end
        end
      end
      -- Every pixel the shader can paint must lie in a tile: sample x across
      -- the half and check the tiles over x cover the curve's line (and fill).
      local bad = nil
      local SAMPLES = 40
      table.sort(list, function(u, v)
        return u.ly < v.ly
      end)
      for j = 0, SAMPLES do
        local x = hd.gw * j / SAMPLES
        local spans = {}
        for _, d in ipairs(list) do
          -- Shared tile edges are inset by 0.02 px (the host's outward
          -- clip rounding covers that sliver), so allow 0.01 units.
          if x >= d.x0 - 0.01 and x <= d.x1 + 0.01 then
            table.insert(spans, { d.ly, d.ly + d.th })
          end
        end
        -- The curve within the shader's 2 px reach of x.
        for _, dx in ipairs({ -2 * px, 0, 2 * px }) do
          local di = 3 + math.clamp(x + dx, 0, hd.gw) / sp
          for _, tex in ipairs(texes) do
            local y = (1 - curveAt(tex, di)) * gh
            local need0, need1 = y - hw, y + hw
            if hd.filled then
              need1 = gh
            end
            need0, need1 = math.max(0, need0), math.min(gh, need1)
            if need1 > need0 + 0.01 then
              local at = need0
              for _, sp2 in ipairs(spans) do
                if sp2[1] <= at + 0.01 and sp2[2] > at then
                  at = sp2[2]
                end
              end
              if at < need1 - 0.01 then
                bad = string.format("x=%.2f needs y %.2f..%.2f, covered to %.2f", x, need0, need1, at)
                break
              end
            end
          end
          if bad then
            break
          end
        end
        if bad then
          break
        end
      end
      if bad then
        fail(string.format("%s: %s", half, bad))
      end
    end
  end
  -- With a viewport, the shape must actually reach the far edges of the box
  -- (that is the point of filling it): full-scale linear bars span the whole
  -- band axis, radial shapes the box's shorter side.
  if case.view ~= nil and case.fill == 1 and (case.shape == "bars" or (case.shape == "radial" and case.bands >= 16)) then
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    local function extent(node)
      local p = node.props or {}
      if p.translateX ~= nil then
        minX, maxX = math.min(minX, p.translateX), math.max(maxX, p.translateX + p.width)
        minY, maxY = math.min(minY, p.translateY), math.max(maxY, p.translateY + p.height)
        return
      end
      for _, ch in ipairs(node.children or {}) do
        extent(ch)
      end
    end
    extent(tree)
    local lo, hi, a0, a1
    if case.shape == "radial" then
      -- The circle spans the view's shorter side.
      if (x1 - x0) <= (y1 - y0) then
        lo, hi, a0, a1 = minX, maxX, x0, x1
      else
        lo, hi, a0, a1 = minY, maxY, y0, y1
      end
    elseif case.vertical then
      lo, hi, a0, a1 = minY, maxY, y0, y1
    else
      lo, hi, a0, a1 = minX, maxX, x0, x1
    end
    local slack = 0.05 * (a1 - a0) + 2
    if lo - a0 > slack or a1 - hi > slack then
      fail(string.format("does not fill the view: drawn %.1f..%.1f of %.1f..%.1f", lo, hi, a0, a1))
    end
  end
  return #msgs == 0, n, msgs
end

-- ── Entry tests ──────────────────────────────────────────────────────────
-- Drive the real bar / desktop entry logic with test doubles: a fake clock,
-- host spectrum frames (bar), cava output lines (desktop), silence, IPC and a
-- missing cava. Runs as a coroutine; `yieldEvery` advances per resume.

-- A getSetting() double over a plain table, resolving dotted paths.
local function fakeSettings(tree)
  return function(path)
    local node = tree
    for part in string.gmatch(path, "[^.]+") do
      if type(node) ~= "table" then
        return nil
      end
      node = node[part]
    end
    return node
  end
end

local function csvFrame(m, t, sep, scale, fmt)
  local vals = Dsp.demo(m, t)
  local parts = table.create(m)
  for i = 1, m do
    parts[i] = string.format(fmt, vals[i] * scale)
  end
  return table.concat(parts, sep)
end

function M.entryTests(log)
  local BarEntry = require("./bar_entry.luau")
  local DesktopEntry = require("./desktop_entry.luau")
  return coroutine.wrap(function()
    local failures, runs = 0, 0
    local function fail(name, msg)
      failures += 1
      log("spectra entrytest FAIL " .. name .. ": " .. msg)
    end
    local function checkTree(name, tree, e)
      local msgs = {}
      local x0, y0, x1, y1 = areaOf(e)
      check(tree, x0, y0, x1, y1, function(m)
        if #msgs < 2 then
          table.insert(msgs, m)
        end
      end)
      if #msgs > 0 then
        fail(name, table.concat(msgs, " | "))
      end
    end

    for _, shape in ipairs(Shapes.ORDER) do
      for _, vertical in ipairs({ false, true }) do
        -- Bar widget: host PipeWire frames, then silence.
        runs += 1
        local name = string.format("bar %s vertical=%s", shape, tostring(vertical))
        local clock = 1000
        local renders, lastTree, visible = 0, nil, true
        local widget = {
          isVertical = function()
            return vertical
          end,
          render = function(tree)
            renders += 1
            lastTree = tree
          end,
          setVisible = function(v)
            visible = v
          end,
          clearTooltip = function() end,
        }
        local cfg = {
          shape = shape,
          audio_spectrum_bands = 24,
          length = 140,
          thickness = 20,
          audio_spectrum = true,
          audio_capture = "system",
        }
        local entry = BarEntry.new(widget, {
          subscribe = noSubscribe,
          nowMs = function()
            return clock
          end,
          setUpdateInterval = function() end,
          log = function() end,
          config = function(k)
            return cfg[k]
          end,
        })
        entry.start()
        for f = 1, 12 do
          clock += 16.7
          entry.onAudioSpectrum(csvFrame(24, clock / 1000, ",", 1, "%.4f"), "1,1")
        end
        if renders < 2 or lastTree == nil then
          fail(name, "rendered " .. renders .. " frames while audio played")
        else
          local e = entry.engine
          checkTree(name, lastTree, e)
        end
        coroutine.yield()
        -- Silence: frames stop; the timer decays and fades to the idle opacity.
        for f = 1, 150 do
          clock += 33
          entry.update()
          if f % 30 == 0 then
            coroutine.yield()
          end
        end
        local e = entry.engine
        if not e.dsp.idle then
          fail(name, "not idle after 5 s of silence")
        elseif math.abs((e.opacity or 1) - e.c.idleOpacity) > 0.01 then
          fail(name, string.format("idle opacity %.2f, expected %.2f", e.opacity or -1, e.c.idleOpacity))
        elseif e.animating then
          fail(name, "still animating after settling")
        end
        local before = renders
        entry.onIpc("next", "")
        if renders == before then
          fail(name, "IPC 'next' did not re-render")
        end
        coroutine.yield()

        -- Desktop widget: cava lines.
        runs += 1
        name = string.format("desktop %s vertical=%s", shape, tostring(vertical))
        clock = 1000
        renders, lastTree = 0, nil
        local onLine, command, written = nil, nil, nil
        local dcfg = {
          shape = shape,
          audio_spectrum_bands = 32,
          orientation = if vertical then "vertical" else "horizontal",
          audio_capture = "system",
        }
        local dw = {
          render = function(tree)
            renders += 1
            lastTree = tree
          end,
          setVisible = function() end,
        }
        local dentry = DesktopEntry.new(dw, {
          subscribe = noSubscribe,
          nowMs = function()
            return clock
          end,
          setUpdateInterval = function() end,
          log = function() end,
          config = function(k)
            return dcfg[k]
          end,
          runStream = function(cmd, cb)
            command, onLine = cmd, cb
            return true
          end,
          commandExists = function()
            return true
          end,
          pluginDataDir = function()
            return "/nonexistent-spectra-test"
          end,
          readFile = function()
            return nil
          end,
          writeFile = function(_, s)
            written = s
            return true
          end,
          mediaPlayer = function()
            return nil
          end,
          -- This instance is placed in a 1376 x 736 box, next to a clock.
          outputName = "DP-1",
          getSetting = fakeSettings({
            desktop_widgets = {
              widget_order = { "desktop-widget-1", "desktop-widget-2" },
              widget = {
                ["desktop-widget-1"] = { type = "clock", box_width = 300, box_height = 100, output = "DP-1" },
                ["desktop-widget-2"] = {
                  type = "kylex/spectra:desktop",
                  box_width = 1376,
                  box_height = 736,
                  output = "DP-1",
                  settings = dcfg,
                },
              },
            },
          }),
        })
        dentry.start()
        if dentry.engine.viewW == nil then
          fail(name, "did not fill its box (no viewport)")
        end
        if onLine == nil or command == nil then
          fail(name, "cava stream not started")
        else
          if not string.find(command, "exec 'cava' -p '/nonexistent-spectra-test/cava-", 1, true) then
            fail(name, "unexpected command " .. command)
          end
          if written == nil or not string.find(written, "bars = 32", 1, true) then
            fail(name, "cava config missing bars = 32")
          end
          for f = 1, 12 do
            clock += 16.7
            onLine(csvFrame(32, clock / 1000, ";", 1000, "%.0f") .. ";")
          end
          if renders < 2 or lastTree == nil then
            fail(name, "rendered " .. renders .. " frames from cava lines")
          else
            local de = dentry.engine
            checkTree(name, lastTree, de)
          end
        end
        coroutine.yield()
      end
    end

    -- Finding this instance's box: settings matching, output filter,
    -- ambiguity, unsized boxes, background padding and the fit math.
    do
      local mine = { shape = "area", audio_spectrum_bands = 256, glow = 10, show_peaks = true }
      local function entryWith(cfg, settingsTree, output)
        return DesktopEntry.new({ render = function() end, setVisible = function() end }, {
          setUpdateInterval = function() end,
          log = function() end,
          config = function(k)
            return cfg[k]
          end,
          commandExists = function()
            return true
          end,
          runStream = function()
            return true
          end,
          pluginDataDir = function()
            return "/nonexistent-spectra-test"
          end,
          readFile = function()
            return nil
          end,
          writeFile = function()
            return true
          end,
          outputName = output,
          getSetting = fakeSettings(settingsTree),
        })
      end
      local function inst(box, settings, output)
        return {
          type = "kylex/spectra:desktop",
          box_width = box[1],
          box_height = box[2],
          output = output or "DP-1",
          settings = settings,
        }
      end
      local function expectView(label, e, w, h)
        runs += 1
        local vw, vh = e.engine.viewW, e.engine.viewH
        if w == nil then
          if vw ~= nil then
            fail("fill " .. label, string.format("expected no viewport, got %.2f x %.2f", vw, vh))
          end
        elseif vw == nil or math.abs(vw - w) > 0.05 or math.abs(vh - h) > 0.05 then
          fail(
            "fill " .. label,
            string.format("expected %.2f x %.2f, got %s x %s", w, h, tostring(vw), tostring(vh))
          )
        end
      end
      -- Your current widget: a 5120 x 1440 box with the default background
      -- (padding 10) and a different Spectra widget on the lock screen. The
      -- 600 x 200 canvas fits by height (1420 / 200 = 7.1), so the box spans
      -- 5100 / 7.1 = 718.31 x 200 canvas units.
      local tree = {
        accessibility = { ui_scale = 1.0 },
        desktop_widgets = {
          widget_order = { "desktop-widget-0000000000000009" },
          widget = { ["desktop-widget-0000000000000009"] = inst({ 5120, 1440 }, mine) },
        },
        lockscreen_widgets = {
          widget_order = { "lockscreen-login-box@DP-1", "lockscreen-widget-0000000000000002" },
          widget = {
            ["lockscreen-widget-0000000000000002"] = inst({ 5088, 416 }, { shape = "bars" }),
          },
        },
      }
      expectView("full-screen box", entryWith(mine, tree), 5100 / 7.1, 200)
      -- The lock-screen instance (different settings) finds its own box:
      -- inner 5068 x 396; height limits the fit (396 / 200 = 1.98).
      expectView("lock-screen box", entryWith({ shape = "bars" }, tree), 5068 / 1.98, 200)
      -- Background off: no padding.
      local noBg = table.clone(mine)
      tree.desktop_widgets.widget["desktop-widget-0000000000000009"].settings =
        { shape = "area", audio_spectrum_bands = 256, glow = 10, show_peaks = true, background = false }
      expectView("no background", entryWith(noBg, tree), 5120 / 7.2, 200)
      -- Two instances with identical settings but different boxes: ambiguous.
      local twin = {
        desktop_widgets = {
          widget_order = { "a", "b" },
          widget = { a = inst({ 1000, 200 }, { shape = "bars" }), b = inst({ 400, 400 }, { shape = "bars" }) },
        },
      }
      expectView("ambiguous twins", entryWith({ shape = "bars" }, twin), nil)
      -- ...unless they are on different outputs.
      twin.desktop_widgets.widget.b.output = "HDMI-A-1"
      expectView("twins on two outputs", entryWith({ shape = "bars" }, twin, "HDMI-A-1"), 380 / (380 / 600), 380 / (380 / 600))
      -- A freshly placed widget has no box yet: keep the natural canvas.
      local unsized = {
        desktop_widgets = { widget_order = { "a" }, widget = { a = inst({ 0, 0 }, nil) } },
      }
      expectView("unsized box", entryWith({}, unsized), nil)
      -- A fixed aspect ratio keeps its proportion (no viewport).
      local fixedCfg = { shape = "bars", aspect = "4:1" }
      local fixed = {
        desktop_widgets = { widget_order = { "a" }, widget = { a = inst({ 1000, 1000 }, { shape = "bars", aspect = "4:1" }) } },
      }
      expectView("fixed aspect", entryWith(fixedCfg, fixed), nil)
      coroutine.yield()
    end

    -- Desktop widget without cava: shows a message instead of failing.
    runs += 1
    local msgTree = nil
    local missing = DesktopEntry.new({
      render = function(tree)
        msgTree = tree
      end,
      setVisible = function() end,
    }, {
      setUpdateInterval = function() end,
      log = function() end,
      config = function()
        return nil
      end,
      commandExists = function()
        return false
      end,
      runStream = function()
        error("runStream must not be called without cava")
      end,
      getSetting = fakeSettings({}),
      subscribe = noSubscribe,
    })
    missing.start()
    if msgTree == nil or msgTree.props.key ~= "canvas-msg" then
      fail("desktop cava-missing", "no message rendered")
    end

    -- Player capture (the default): capture.sh follows the active MPRIS
    -- player through a control file and relays cava's frames plus '#' status
    -- lines. Desktop first, then the bar (which then ignores the shell's
    -- spectrum).
    for _, kind in ipairs({ "desktop", "bar" }) do
      runs += 1
      local name = kind .. " player capture"
      local clock = 1000
      local renders = 0
      local streams = {} -- { cmd, cb } per runStream call
      local files = {}
      local player = { busName = "org.mpris.MediaPlayer2.first", status = "Playing" }
      local overrides = {
        subscribe = noSubscribe,
        nowMs = function()
          return clock
        end,
        setUpdateInterval = function() end,
        log = function() end,
        tr = function(k)
          return k
        end,
        config = function(k)
          return ({ shape = "bars", audio_spectrum_bands = 32 })[k]
        end,
        runStream = function(cmd, cb)
          table.insert(streams, { cmd = cmd, cb = cb })
          return true
        end,
        commandExists = function()
          return true
        end,
        pluginDataDir = function()
          return "/nonexistent-spectra-test"
        end,
        pluginDir = function()
          return "/plugin"
        end,
        readFile = function(path)
          return files[path]
        end,
        writeFile = function(path, text)
          files[path] = text
          return true
        end,
        mediaPlayer = function()
          return player
        end,
        getSetting = fakeSettings({}),
      }
      local widget = {
        isVertical = function()
          return false
        end,
        render = function()
          renders += 1
        end,
        setVisible = function() end,
        clearTooltip = function() end,
      }
      local entry = if kind == "desktop" then DesktopEntry.new(widget, overrides) else BarEntry.new(widget, overrides)
      entry.start()
      local cap = entry.capture
      local first = streams[1]
      local ctl = nil
      local conf = nil
      if cap == nil or first == nil then
        fail(name, "no capture started")
      else
        ctl = string.match(first.cmd, "capture%.sh' '([^']+)'")
        conf = string.match(first.cmd, "' '[^']+' '[^']+' '([^']+)'$")
        if not string.find(first.cmd, "exec bash '/plugin/lib/capture.sh' '", 1, true) or ctl == nil or conf == nil then
          fail(name, "unexpected command " .. first.cmd)
        elseif files[ctl] ~= "org.mpris.MediaPlayer2.first\n" then
          fail(name, "control file holds " .. tostring(files[ctl]))
        elseif
          files[conf] == nil
          or not string.find(files[conf], "method = pipewire", 1, true)
          or not string.find(files[conf], "source = auto", 1, true)
          or not string.find(files[conf], "bars = 32", 1, true)
        then
          fail(name, "cava config: " .. tostring(files[conf]))
        end
      end
      if cap ~= nil and first ~= nil and ctl ~= nil then
        local line = first.cb
        -- The bar ignores the shell's spectrum in player mode.
        if kind == "bar" then
          local before = renders
          for _ = 1, 6 do
            clock += 16.7
            entry.onAudioSpectrum(csvFrame(32, clock / 1000, ",", 1, "%.4f"), "1,1")
          end
          if renders ~= before then
            fail(name, "drew the shell's spectrum in player mode")
          end
        end
        line("#alive")
        line("#target 4242 org.mpris.MediaPlayer2.first")
        if cap.target ~= "4242" then
          fail(name, "target not recorded: " .. tostring(cap.target))
        end
        local before = renders
        for _ = 1, 12 do
          clock += 16.7
          line(csvFrame(32, clock / 1000, ";", 1000, "%.0f") .. ";")
        end
        if renders - before < 2 then
          fail(name, "rendered " .. (renders - before) .. " frames from the player's audio")
        end
        if not cap.update(clock) then
          fail(name, "not fed while the player's frames arrive")
        end
        -- Another player becomes active, then none.
        player = { busName = "org.mpris.MediaPlayer2.second", status = "Playing" }
        clock += 400
        entry.update()
        if files[ctl] ~= "org.mpris.MediaPlayer2.second\n" then
          fail(name, "did not follow the new player: " .. tostring(files[ctl]))
        end
        player = nil
        clock += 400
        entry.update()
        if files[ctl] ~= "\n" then
          fail(name, "did not clear the player: " .. tostring(files[ctl]))
        end
        -- No stream: silence decays to idle from the timer; heartbeats
        -- keep the supervisor alive.
        line("#none")
        if cap.target ~= nil then
          fail(name, "target kept after #none")
        end
        for f = 1, 200 do
          clock += 33
          if f % 100 == 0 then
            line("#alive")
          end
          entry.update()
        end
        if not entry.engine.dsp.idle then
          fail(name, "not idle without a player stream")
        end
        if #streams ~= 1 then
          fail(name, "restarted a live supervisor (" .. #streams .. " streams)")
        end
        -- A dead supervisor (no heartbeat) is restarted, with a fresh
        -- control file holding the current player.
        player = { busName = "org.mpris.MediaPlayer2.third", status = "Playing" }
        for _ = 1, 450 do
          clock += 33
          entry.update()
        end
        if #streams < 2 then
          fail(name, "dead supervisor not restarted")
        else
          local ctl2 = string.match(streams[2].cmd, "capture%.sh' '([^']+)'")
          if ctl2 == nil or ctl2 == ctl or files[ctl2] ~= "org.mpris.MediaPlayer2.third\n" then
            fail(name, "restart control file " .. tostring(ctl2) .. " = " .. tostring(ctl2 and files[ctl2]))
          end
        end
      end
      coroutine.yield()
    end

    -- Pause while fullscreen: compositor window snapshots hide the bar widget
    -- only for a visible fullscreen window on its own output.
    runs += 1
    do
      local name = "bar pause_fullscreen"
      local clock = 1000
      local renders, visible = 0, true
      local onWindows, subscribedEvents = nil, nil
      local fentry = BarEntry.new({
        isVertical = function()
          return false
        end,
        render = function()
          renders += 1
        end,
        setVisible = function(v)
          visible = v
        end,
        outputName = function()
          return "DP-1"
        end,
      }, {
        nowMs = function()
          return clock
        end,
        setUpdateInterval = function() end,
        log = function() end,
        config = function(k)
          return ({ shape = "bars", audio_spectrum_bands = 24, audio_capture = "system" })[k]
        end,
        subscribe = function(options, cb)
          subscribedEvents = options.events
          onWindows = cb
          return 1
        end,
      })
      fentry.start()
      local function snapshot(windows)
        onWindows("windows", windows)
      end
      local function play()
        for _ = 1, 6 do
          clock += 16.7
          fentry.onAudioSpectrum(csvFrame(24, clock / 1000, ",", 1, "%.4f"), "1,1")
        end
      end
      if onWindows == nil or subscribedEvents == nil or subscribedEvents[1] ~= "windows" then
        fail(name, "did not subscribe to window events")
      else
        snapshot({ { output = "DP-2", fullscreen = true, visible = true } })
        if fentry.engine.paused then
          fail(name, "paused for a fullscreen window on another output")
        end
        snapshot({ { output = "DP-1", fullscreen = true, visible = true, minimized = true } })
        if fentry.engine.paused then
          fail(name, "paused for a minimized fullscreen window")
        end
        snapshot({ { output = "DP-1", fullscreen = false }, { output = "DP-1", fullscreen = true, visible = true } })
        local before = renders
        play()
        if not fentry.engine.paused or visible then
          fail(name, "not hidden while fullscreen")
        elseif renders ~= before then
          fail(name, "rendered " .. (renders - before) .. " frames while fullscreen")
        end
        snapshot({ { output = "DP-1", fullscreen = false, visible = true } })
        before = renders
        play()
        if fentry.engine.paused or not visible then
          fail(name, "not shown after the fullscreen window left")
        elseif renders == before then
          fail(name, "no frames after resuming")
        end
      end
    end

    -- pause_fullscreen = false: never subscribes.
    runs += 1
    do
      local subscribed = false
      local off = BarEntry.new({
        isVertical = function()
          return false
        end,
        render = function() end,
        setVisible = function() end,
      }, {
        nowMs = function()
          return 1000
        end,
        setUpdateInterval = function() end,
        log = function() end,
        config = function(k)
          return ({ pause_fullscreen = false, audio_capture = "system" })[k]
        end,
        runStream = function()
          return true
        end,
        subscribe = function()
          subscribed = true
          return 1
        end,
      })
      off.start()
      if subscribed then
        fail("bar pause_fullscreen off", "subscribed although the setting is off")
      end
    end

    log(string.format("spectra entrytest done: %d runs, %d failures", runs, failures))
    return true
  end)
end

-- CPU cost of one shape at the desktop defaults (64 bands, 600-unit canvas,
-- demo signal): tree building per frame, and the host's render() of it.
-- `payload` is "<shape> [bands] [glow] [px per unit]".
function M.bench(payload: string?, renderFn)
  if payload == "calibrate" then
    -- Host metering cost: an empty loop iteration, a Luau call, a 4x-unrolled
    -- loop body, and a C builtin call that is not a fastcall.
    local N = 2000
    local function f() end
    local c0 = os.clock()
    for _ = 1, N do
    end
    local loopUs = (os.clock() - c0) * 1e6 / N
    c0 = os.clock()
    for _ = 1, N do
      f()
    end
    local callUs = (os.clock() - c0) * 1e6 / N - loopUs
    local t = table.create(N, 0.5)
    c0 = os.clock()
    local acc = 0
    for i = 1, N do
      acc += t[i] * 2 + 1
    end
    local bodyUs = (os.clock() - c0) * 1e6 / N
    c0 = os.clock()
    for i = 1, N, 4 do
      acc += t[i] * 2 + 1
      acc += t[i + 1] * 2 + 1
      acc += t[i + 2] * 2 + 1
      acc += t[i + 3] * 2 + 1
    end
    local unrolledUs = (os.clock() - c0) * 1e6 / N
    c0 = os.clock()
    for _ = 1, N do
      local _ = table.create(4)
    end
    local cCallUs = (os.clock() - c0) * 1e6 / N - loopUs
    noctalia.log(string.format(
      "spectra calibrate: loop %.3f us/iter, Luau call %.3f us, body %.3f us/elem, unrolled x4 %.3f us/elem, table.create %.3f us",
      loopUs, callUs, bodyUs, unrolledUs, cCallUs
    ))
    return
  end
  local parts = string.split(payload or "", " ")
  local shape = parts[1] or "bars"
  local bands = tonumber(parts[2]) or 64
  local glow = tonumber(parts[3]) or 0
  -- Extra settings as key=value words after the px / unit, e.g.
  -- "wave 128 0 7.2 color_mode=level show_peaks=true view=711.11x200".
  local extra = {}
  local view = nil
  for i = 5, #parts do
    local k, v = string.match(parts[i], "^([%w_]+)=(.+)$")
    if k == "view" then
      local vw, vh = string.match(v, "^([%d.]+)x([%d.]+)$")
      view = { tonumber(vw), tonumber(vh) }
    elseif k ~= nil then
      extra[k] = if v == "true" then true elseif v == "false" then false else (tonumber(v) or v)
    end
  end
  local c = Engine.readConfig(BASE, function(key)
    if extra[key] ~= nil then
      return extra[key]
    end
    if key == "shape" then
      return shape
    elseif key == "audio_spectrum_bands" then
      return bands
    elseif key == "glow" then
      return glow
    elseif key == "segments" then
      return 16
    elseif key == "history" then
      return 32
    end
    return nil
  end)
  local e = Engine.new(c)
  e.demo = true
  e.pxPerUnit = tonumber(parts[4]) or 1.5 -- screen px per canvas unit
  if Shapes.RADIAL[shape] then
    e:setGeometry(600, 600, false)
  else
    e:setGeometry(600, 200, false)
  end
  if view ~= nil then
    e:setViewport(view[1], view[2])
  end
  local t = noctalia.nowMs()
  e:advance(t, nil, true)
  local frames = 3
  local c0 = os.clock()
  local tree = e.lastTree
  for f = 1, frames do
    t += 16
    tree = e:advance(t, nil, true) or tree
  end
  local buildMs = (os.clock() - c0) * 1000 / frames
  -- Breakdown: synthetic signal, DSP step, shape only, shape + compose.
  local raw = Dsp.demo(48, 1.3)
  local c1 = os.clock()
  for _ = 1, frames do
    Dsp.demo(48, 1.3, raw)
  end
  local demoMs = (os.clock() - c1) * 1000 / frames
  -- The DSP as fed in production: a split cava line, one field per band.
  local na = e.dsp.na
  local line = Dsp.demo(na, 1.7)
  for i = 1, na do
    line[i] = tostring(math.floor(line[i] * 1000))
  end
  local cavaLine = table.concat(line, ";") .. ";"
  c1 = os.clock()
  for _ = 1, frames do
    local parts = string.split(cavaLine, ";")
    parts[#parts] = nil
    e.dsp:step(parts, 16, 0.001)
  end
  local dspMs = (os.clock() - c1) * 1000 / frames
  c1 = os.clock()
  for _ = 1, frames do
    e:render(1.3, true)
  end
  local renderLuaMs = (os.clock() - c1) * 1000 / frames
  local ctx = e.ctx
  c1 = os.clock()
  for _ = 1, frames do
    ctx.out = {}
    Shapes[e:shape()](ctx)
  end
  local shapeMs = (os.clock() - c1) * 1000 / frames
  local nodes = 0
  local function count(n)
    nodes += 1
    for _, ch in ipairs(n.children or {}) do
      count(ch)
    end
  end
  count(tree)
  local c1 = os.clock()
  renderFn(tree)
  local renderMs = (os.clock() - c1) * 1000
  noctalia.log(
    string.format(
      "spectra bench [%s] nodes=%4d build=%.2fms render=%.2fms | demo=%.2f dsp=%.2f shape=%.2f compose=%.2f",
      payload or "",
      nodes,
      buildMs,
      renderMs,
      demoMs,
      dspMs,
      shapeMs,
      renderLuaMs - shapeMs
    )
  )
end

-- Incremental runner: call step(budgetMs) until it returns true.
function M.runner()
  local cases = M.cases()
  local i = 0
  local stats = {}
  local failures = 0
  local started = noctalia.nowMs()
  local self = {}
  -- One case per call: a budget overrun inside pcall would otherwise be
  -- swallowed and the rest of the call would run unmetered.
  function self.step(_budgetMs)
    while i < #cases do
      i += 1
      local case = cases[i]
      local t0 = os.clock()
      local ok, err = pcall(function()
        local good, nodes, msgs = M.run(case)
        local ms = (os.clock() - t0) * 1000
        if ms > 6 then
          noctalia.log(string.format("spectra selftest SLOW %s bands=%d: %.1f ms", case.shape, case.bands, ms))
        end
        local s = stats[case.shape] or { cases = 0, fails = 0, maxNodes = 0 }
        stats[case.shape] = s
        s.cases += 1
        s.maxNodes = math.max(s.maxNodes, nodes)
        if not good then
          s.fails += 1
          failures += 1
          if s.fails <= 2 then
            noctalia.log(
              string.format(
                "spectra selftest FAIL %s bands=%d fill=%s %gx%g vertical=%s over=%s: %s",
                case.shape,
                case.bands,
                tostring(case.fill),
                case.w,
                case.h,
                tostring(case.vertical),
                noctalia.json.encode(case.over) or "",
                table.concat(msgs, " | ")
              )
            )
          end
        end
      end)
      if not ok then
        failures += 1
        noctalia.log("spectra selftest ERROR " .. case.shape .. ": " .. tostring(err))
      end
      if i < #cases then
        return false
      end
    end
    for _, name in ipairs(Shapes.ORDER) do
      local s = stats[name]
      if s then
        noctalia.log(
          string.format("spectra selftest %-12s cases=%3d fails=%d maxNodes=%d", name, s.cases, s.fails, s.maxNodes)
        )
      end
    end
    noctalia.log(
      string.format(
        "spectra selftest done: %d cases, %d failures, %.0f ms",
        #cases,
        failures,
        noctalia.nowMs() - started
      )
    )
    return true
  end
  return self
end

return M
