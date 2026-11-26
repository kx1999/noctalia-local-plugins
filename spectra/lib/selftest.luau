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
    for _, child in ipairs(node.children or {}) do
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
  -- Area / wave slices: each clipped graph's plot range must be exactly the
  -- visible height (the shader's padding compensated), start at the slice's
  -- edge, be one band interval wider than the canvas (so the last band sits
  -- on the edge) and show band 1 as its first visible sample.
  if case.shape == "area" or case.shape == "wave" then
    local ctx = e.ctx
    local gh = if e.c.baseline == "center" then ctx.H / 2 else ctx.H
    local lw = math.max(0.5, e.c.lineWidth)
    local nb = e.dsp.n
    for _, p in ipairs(ctx.out) do
      local col = p.node
      if p.kind == "node" and col ~= nil and col.props.clip then
        local g = col.children[1].children[1].props
        local pad = Shapes.graphPad(g.height * ctx.pxPerUnit, lw * ctx.pxPerUnit)
        local plot = g.height * (1 - 2 * pad)
        if math.abs(plot - gh) > 0.05 then
          fail(string.format("%s: plot range %.2f, visible %.2f", p.key, plot, gh))
          break
        end
        local top = g.translateY + pad * g.height -- = -(slice offset), <= 0
        if top > 0.01 or top < -gh - 0.01 then
          fail(string.format("%s: plot top at %.2f", p.key, top))
          break
        end
        local expectW = if nb > 1 then ctx.W * nb / (nb - 1) else ctx.W
        if math.abs(g.width - expectW) > 0.05 or #g.values ~= nb + 3 then
          fail(string.format("%s: graph width %.2f (want %.2f), %d samples", p.key, g.width, expectW, #g.values))
          break
        end
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
        local cfg = { shape = shape, audio_spectrum_bands = 24, length = 140, thickness = 20, audio_spectrum = true }
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
        local dcfg = { shape = shape, audio_spectrum_bands = 32, orientation = if vertical then "vertical" else "horizontal" }
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
          return ({ shape = "bars", audio_spectrum_bands = 24 })[k]
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
          return ({ pause_fullscreen = false })[k]
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
  local parts = string.split(payload or "", " ")
  local shape = parts[1] or "bars"
  local bands = tonumber(parts[2]) or 64
  local glow = tonumber(parts[3]) or 0
  local c = Engine.readConfig(BASE, function(key)
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
  local t = noctalia.nowMs()
  e:advance(t, nil, true)
  local frames = 5
  local c0 = os.clock()
  local tree
  for f = 1, frames do
    t += 16
    tree = e:advance(t, nil, true) or tree
  end
  local buildMs = (os.clock() - c0) * 1000 / frames
  local nodes = 0
  local function count(n)
    nodes += 1
    for _, ch in ipairs(n.children) do
      count(ch)
    end
  end
  count(tree)
  local c1 = os.clock()
  renderFn(tree)
  local renderMs = (os.clock() - c1) * 1000
  noctalia.log(
    string.format(
      "spectra bench %-12s bands=%d glow=%d nodes=%4d build=%.2fms render=%.2fms",
      shape,
      bands,
      glow,
      nodes,
      buildMs,
      renderMs
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
