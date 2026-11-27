--!nonstrict
-- Every visualizer shape. A shape reads `ctx` and appends primitives (see
-- canvas.luau) to `ctx.out`. Linear shapes work in a horizontal frame of
-- ctx.W x ctx.H (bands left -> right, amplitude growing away from the
-- baseline); radial shapes draw around the canvas center. Every shape keeps
-- its primitives inside the canvas at full scale (lib/selftest.luau checks).
--
-- ctx fields: W, H, n, values, peaks (display order), spectrum, spectrumPeaks
-- (low -> high), pal (Palette), c (normalized settings), t (seconds),
-- state (per-shape scratch table, reset when the shape changes), out.
--
-- These loops run every frame under Noctalia's per-call CPU metering, so they
-- avoid helper calls per element: colors come from cached arrays
-- (Palette:colors) and keys from cached string tables.

local Dsp = require("./dsp.luau")
local Canvas = require("./canvas.luau")
local Color = require("./color.luau")

-- "By level" color arrays hold LV + 1 entries (index = level * LV + 1).
local LV = Color.LEVELS
local LV1 = LV + 1

local S = {}

local CLEAR = Canvas.CLEAR
local NO_CHILDREN = Canvas.NO_CHILDREN
local DEG = math.pi / 180
local floor, min, max, abs, sqrt, sin, cos = math.floor, math.min, math.max, math.abs, math.sqrt, math.sin, math.cos

-- Shape catalogue in cycling order.
S.ORDER = {
  "bars",
  "blocks",
  "dots",
  "dot_matrix",
  "bubbles",
  "lollipops",
  "peaks",
  "wave",
  "area",
  "text",
  "braille",
  "spectrogram",
  "meter",
  "pulse",
  "radial",
  "radial_dots",
  "circle_wave",
  "bloom",
  "spiral",
  "rings",
}

-- Radial shapes get a square canvas and the mirrored layout on "auto".
S.RADIAL = {
  pulse = true,
  radial = true,
  radial_dots = true,
  circle_wave = true,
  bloom = true,
  spiral = true,
  rings = true,
}

-- Shapes that always read the spectrum low -> high.
S.FIXED_LAYOUT = { pulse = true, meter = true, rings = true }

-- KEYS.b[12] == "b12", built once.
local KEYS = setmetatable({}, {
  __index = function(t, prefix)
    local m = setmetatable({}, {
      __index = function(tt, i)
        local v = prefix .. i
        tt[i] = v
        return v
      end,
    })
    t[prefix] = m
    return m
  end,
})

-- Catmull-Rom resampler, defined with the radial shapes below.
local smooth
-- Cached glyph maps for the text shape, defined with it.
local textMaps

-- Horizontal band geometry: bar width, gap and the left edge of bar 1.
local function columns(ctx, n)
  local W = ctx.W
  local c = ctx.c
  n = n or ctx.n
  local gap = max(0, c.spacing)
  local bw
  if c.barWidth > 0 then
    bw = c.barWidth
    local total = n * bw + (n - 1) * gap
    if total > W then
      local s = W / total
      bw *= s
      gap *= s
    end
  else
    bw = (W - (n - 1) * gap) / n
    if bw < 0.5 then
      gap = if n > 1 then max(0, (W - n * 0.5) / (n - 1)) else 0
      bw = (W - (n - 1) * gap) / n
    end
  end
  local total = n * bw + (n - 1) * gap
  return bw, gap, (W - total) / 2
end

-- Room reserved for peak caps beyond the bars.
local function peakRoom(c)
  return if c.showPeaks then c.peakThickness + 1 else 0
end

-- ── Linear shapes ───────────────────────────────────────────────────────────

function S.bars(ctx)
  local c, pal, n, H, out = ctx.c, ctx.pal, ctx.n, ctx.H, ctx.out
  local values, peaks = ctx.values, ctx.peaks
  local bw, gap, x0 = columns(ctx)
  local center, top = c.baseline == "center", c.baseline == "top"
  local room = peakRoom(c)
  local span = max(1, if center then H - 2 * room else H - room)
  local minS = min(c.minSize, span)
  local round = c.roundness * 0.5
  local cols, lv = pal:colors(n)
  local tracks = if c.barTracks then pal:colors(n, pal.trackAlpha) else nil
  local peakCol = pal.peakToken ~= nil and pal:peak(1, n, 1) or nil
  local kb, kt, kp, kq = KEYS.b, KEYS.t, KEYS.p, KEYS.q
  local pt = c.peakThickness
  local pr = min(pt, bw) / 2 * c.roundness
  for i = 1, n do
    local v = values[i]
    local cx = x0 + (i - 1) * (bw + gap) + bw / 2
    if tracks ~= nil then
      local ty = if center then H / 2 elseif top then span / 2 else H - span / 2
      out[#out + 1] = {
        kind = "box",
        key = kt[i],
        cx = cx,
        cy = ty,
        w = bw,
        h = span,
        fill = tracks[if lv then LV1 else i],
        radius = round * min(bw, span),
        glow = false,
      }
    end
    local L = minS + v * (span - minS)
    local cy = if center then H / 2 elseif top then L / 2 else H - L / 2
    local col = cols[if lv then (v * LV + 0.5) // 1 + 1 else i]
    out[#out + 1] = {
      kind = "box",
      key = kb[i],
      cx = cx,
      cy = cy,
      w = bw,
      h = L,
      fill = col,
      radius = round * min(bw, L),
      glow = true,
    }
    if room > 0 then
      local pv = peaks[i]
      local pl = minS + pv * (span - minS)
      local pcol = peakCol or cols[if lv then (pv * LV + 0.5) // 1 + 1 else i]
      local py = if center then H / 2 - (pl / 2 + 1 + pt / 2) elseif top then pl + 1 + pt / 2 else H - pl - 1 - pt / 2
      out[#out + 1] = { kind = "box", key = kp[i], cx = cx, cy = py, w = bw, h = pt, fill = pcol, radius = pr, glow = true }
      if center then
        out[#out + 1] = {
          kind = "box",
          key = kq[i],
          cx = cx,
          cy = H / 2 + (pl / 2 + 1 + pt / 2),
          w = bw,
          h = pt,
          fill = pcol,
          radius = pr,
          glow = true,
        }
      end
    end
  end
end

-- Falling peak caps over faint ghost bars.
function S.peaks(ctx)
  local c, pal, n, H, out = ctx.c, ctx.pal, ctx.n, ctx.H, ctx.out
  local values, peaks = ctx.values, ctx.peaks
  local bw, gap, x0 = columns(ctx)
  local pt = max(c.peakThickness, 2)
  local room = pt + 1
  local center, top = c.baseline == "center", c.baseline == "top"
  local span = max(1, if center then H - 2 * room else H - room)
  local minS = min(c.minSize, span)
  local round = c.roundness * 0.5
  local cols, lv = pal:colors(n)
  local ghosts = pal:colors(n, 0.22)
  local peakCol = pal.peakToken ~= nil and pal:peak(1, n, 1) or nil
  local kg, kp, kq = KEYS.g, KEYS.p, KEYS.q
  local r = min(pt, bw) / 2 * c.roundness
  for i = 1, n do
    local v = values[i]
    local cx = x0 + (i - 1) * (bw + gap) + bw / 2
    local L = minS + v * (span - minS)
    local cy = if center then H / 2 elseif top then L / 2 else H - L / 2
    out[#out + 1] = {
      kind = "box",
      key = kg[i],
      cx = cx,
      cy = cy,
      w = bw,
      h = L,
      fill = ghosts[if lv then (v * LV + 0.5) // 1 + 1 else i],
      radius = round * min(bw, L),
      glow = false,
    }
    local pv = peaks[i]
    local pl = minS + pv * (span - minS)
    local col = peakCol or cols[if lv then (pv * LV + 0.5) // 1 + 1 else i]
    if center then
      local off = pl / 2 + 1 + pt / 2
      out[#out + 1] = {
        kind = "box",
        key = kp[i],
        cx = cx,
        cy = H / 2 - off,
        w = bw,
        h = pt,
        fill = col,
        radius = r,
        glow = true,
      }
      out[#out + 1] = {
        kind = "box",
        key = kq[i],
        cx = cx,
        cy = H / 2 + off,
        w = bw,
        h = pt,
        fill = col,
        radius = r,
        glow = true,
      }
    elseif top then
      out[#out + 1] = {
        kind = "box",
        key = kp[i],
        cx = cx,
        cy = pl + 1 + pt / 2,
        w = bw,
        h = pt,
        fill = col,
        radius = r,
        glow = true,
      }
    else
      out[#out + 1] = {
        kind = "box",
        key = kp[i],
        cx = cx,
        cy = H - pl - 1 - pt / 2,
        w = bw,
        h = pt,
        fill = col,
        radius = r,
        glow = true,
      }
    end
  end
end

-- One dot per band riding at the band's level.
function S.dots(ctx)
  -- Emitted in layers (tracks, then the rest), which never overlap across
  -- bands: each layer is a run of equal-size nodes the canvas packs together.
  local lt, lm, lp = {}, {}, {}
  local c, pal, n, H, out = ctx.c, ctx.pal, ctx.n, ctx.H, ctx.out
  local values, peaks = ctx.values, ctx.peaks
  local bw, gap, x0 = columns(ctx)
  local d = max(1, min(bw, H * 0.5))
  local pd = max(1, d * 0.45)
  local room = if c.showPeaks then pd + 1 else 0
  local center, top = c.baseline == "center", c.baseline == "top"
  -- Dot centers travel this far from the baseline position.
  local travel = max(0, if center then H - d - 2 * room else H - d - room)
  local cols, lv = pal:colors(n)
  local tracks = if c.barTracks then pal:colors(n, pal.trackAlpha) else nil
  local peakCol = pal.peakToken ~= nil and pal:peak(1, n, 1) or nil
  local ka, kb, kt, kp, kq = KEYS.a, KEYS.b, KEYS.t, KEYS.p, KEYS.q
  local sw = max(1, d * 0.25)
  for i = 1, n do
    local v = values[i]
    local cx = x0 + (i - 1) * (bw + gap) + bw / 2
    local col = cols[if lv then (v * LV + 0.5) // 1 + 1 else i]
    if tracks ~= nil then
      lt[#lt + 1] = {
        kind = "box",
        key = kt[i],
        cx = cx,
        cy = H / 2,
        w = sw,
        h = H,
        fill = tracks[if lv then LV1 else i],
        radius = sw / 2,
        glow = false,
      }
    end
    if center then
      local off = v * travel / 2
      lm[#lm + 1] = {
        kind = "box",
        key = ka[i],
        cx = cx,
        cy = H / 2 - off,
        w = d,
        h = d,
        fill = col,
        radius = d / 2,
        glow = true,
      }
      if off > 0.5 then
        lm[#lm + 1] = {
          kind = "box",
          key = kb[i],
          cx = cx,
          cy = H / 2 + off,
          w = d,
          h = d,
          fill = col,
          radius = d / 2,
          glow = true,
        }
      end
    elseif top then
      lm[#lm + 1] = {
        kind = "box",
        key = ka[i],
        cx = cx,
        cy = d / 2 + v * travel,
        w = d,
        h = d,
        fill = col,
        radius = d / 2,
        glow = true,
      }
    else
      lm[#lm + 1] = {
        kind = "box",
        key = ka[i],
        cx = cx,
        cy = H - d / 2 - v * travel,
        w = d,
        h = d,
        fill = col,
        radius = d / 2,
        glow = true,
      }
    end
    if room > 0 then
      local pv = peaks[i]
      local pcol = peakCol or cols[if lv then (pv * LV + 0.5) // 1 + 1 else i]
      local off = d / 2 + 1 + pd / 2
      if center then
        local y = pv * travel / 2 + off
        lp[#lp + 1] = {
          kind = "box",
          key = kp[i],
          cx = cx,
          cy = H / 2 - y,
          w = pd,
          h = pd,
          fill = pcol,
          radius = pd / 2,
          glow = true,
        }
        lp[#lp + 1] = {
          kind = "box",
          key = kq[i],
          cx = cx,
          cy = H / 2 + y,
          w = pd,
          h = pd,
          fill = pcol,
          radius = pd / 2,
          glow = true,
        }
      elseif top then
        lp[#lp + 1] = {
          kind = "box",
          key = kp[i],
          cx = cx,
          cy = d / 2 + pv * travel + off,
          w = pd,
          h = pd,
          fill = pcol,
          radius = pd / 2,
          glow = true,
        }
      else
        lp[#lp + 1] = {
          kind = "box",
          key = kp[i],
          cx = cx,
          cy = H - d / 2 - pv * travel - off,
          w = pd,
          h = pd,
          fill = pcol,
          radius = pd / 2,
          glow = true,
        }
      end
    end
  end
  table.move(lt, 1, #lt, #out + 1, out)
  table.move(lm, 1, #lm, #out + 1, out)
  table.move(lp, 1, #lp, #out + 1, out)
end

-- Thin stems with a round head.
function S.lollipops(ctx)
  -- Emitted in layers (tracks, then the rest), which never overlap across
  -- bands: each layer is a run of equal-size nodes the canvas packs together.
  local lt, ls, lh = {}, {}, {}
  local c, pal, n, H, out = ctx.c, ctx.pal, ctx.n, ctx.H, ctx.out
  local values = ctx.values
  local bw, gap, x0 = columns(ctx)
  local d = max(2, min(bw, H * 0.4))
  local sw = max(1, bw * 0.28)
  local center, top = c.baseline == "center", c.baseline == "top"
  local travel = max(0, H - d)
  local cols, lv = pal:colors(n)
  local tracks = if c.barTracks then pal:colors(n, pal.trackAlpha) else nil
  local ka, kb, ks, kt = KEYS.a, KEYS.b, KEYS.s, KEYS.t
  for i = 1, n do
    local v = values[i]
    local cx = x0 + (i - 1) * (bw + gap) + bw / 2
    local col = cols[if lv then (v * LV + 0.5) // 1 + 1 else i]
    if tracks ~= nil then
      lt[#lt + 1] = {
        kind = "box",
        key = kt[i],
        cx = cx,
        cy = H / 2,
        w = sw,
        h = H,
        fill = tracks[if lv then LV1 else i],
        radius = sw / 2,
        glow = false,
      }
    end
    if center then
      local off = v * travel / 2
      ls[#ls + 1] = {
        kind = "box",
        key = ks[i],
        cx = cx,
        cy = H / 2,
        w = sw,
        h = max(sw, 2 * off),
        fill = col,
        radius = sw / 2,
        glow = true,
      }
      lh[#lh + 1] = {
        kind = "box",
        key = ka[i],
        cx = cx,
        cy = H / 2 - off,
        w = d,
        h = d,
        fill = col,
        radius = d / 2,
        glow = true,
      }
      lh[#lh + 1] = {
        kind = "box",
        key = kb[i],
        cx = cx,
        cy = H / 2 + off,
        w = d,
        h = d,
        fill = col,
        radius = d / 2,
        glow = true,
      }
    else
      local hy = if top then d / 2 + v * travel else H - d / 2 - v * travel
      local base = if top then 0 else H
      local len = abs(base - hy)
      if len > 0.5 then
        ls[#ls + 1] = {
          kind = "box",
          key = ks[i],
          cx = cx,
          cy = (base + hy) / 2,
          w = sw,
          h = len,
          fill = col,
          radius = sw / 2,
          glow = true,
        }
      end
      lh[#lh + 1] = {
        kind = "box",
        key = ka[i],
        cx = cx,
        cy = hy,
        w = d,
        h = d,
        fill = col,
        radius = d / 2,
        glow = true,
      }
    end
  end
  table.move(lt, 1, #lt, #out + 1, out)
  table.move(ls, 1, #ls, #out + 1, out)
  table.move(lh, 1, #lh, #out + 1, out)
end

-- Circles whose size follows the band level.
function S.bubbles(ctx)
  local c, pal, n, W, H, out = ctx.c, ctx.pal, ctx.n, ctx.W, ctx.H, ctx.out
  local values = ctx.values
  local bw, gap, x0 = columns(ctx)
  local dMax = max(2, min(H, (bw + gap) * 1.6, W))
  local dMin = math.clamp(c.minSize, 0, dMax)
  local cols, lv = pal:colors(n, 0.85)
  local kb = KEYS.b
  local center, top = c.baseline == "center", c.baseline == "top"
  for i = 1, n do
    local v = values[i]
    local d = dMin + v * (dMax - dMin)
    if d >= 0.5 then
      -- Edge bubbles slide inward so they never leave the canvas.
      local cx = math.clamp(x0 + (i - 1) * (bw + gap) + bw / 2, d / 2, W - d / 2)
      local cy = if center then H / 2 elseif top then d / 2 else H - d / 2
      out[#out + 1] = {
        kind = "box",
        key = kb[i],
        cx = cx,
        cy = cy,
        w = d,
        h = d,
        fill = cols[if lv then (v * LV + 0.5) // 1 + 1 else i],
        radius = d / 2,
        glow = true,
      }
    end
  end
end

-- A grid of cells (blocks / dot matrix) built as plain flex: cell sizes are
-- constant, so layout stays stable and only fills change between frames.
local function cellGrid(ctx, round: boolean)
  local c, pal, n, H = ctx.c, ctx.pal, ctx.n, ctx.H
  local values, peaks = ctx.values, ctx.peaks
  local bw, gap, x0 = columns(ctx)
  local sg = max(0, c.segmentGap)
  local k = max(1, c.segments)
  local segH = (H - (k - 1) * sg) / k
  if segH < 1 then
    k = max(1, floor((H + sg) / (1 + sg)))
    segH = (H - (k - 1) * sg) / k
  end
  local cw, chh = bw, segH
  if round then
    local d = min(bw, segH)
    cw, chh = d, d
  end
  local vgap = if k > 1 then (H - k * chh) / (k - 1) else 0
  local radius = if round then cw / 2 else c.roundness * min(cw, chh) / 2
  local base = c.baseline
  local center, top = base == "center", base == "top"
  local minLit = if c.minSize > 0 then 1 else 0
  local cols, lv = pal:colors(n)
  local tracks = if pal.trackAlpha > 0 then pal:colors(n, pal.trackAlpha) else nil
  local peakCol = pal.peakToken ~= nil and pal:peak(1, n, 1) or nil
  local showPeaks = c.showPeaks
  local kc, kk = KEYS.c, KEYS.k
  local half = (k + 1) / 2
  -- Centered runs step `pos` by 2 (one cell each side), others by 1.
  local peakSpan = if center then 2 else 1
  local colsOut = table.create(n)
  -- Reuse a band's column when its lit / peak counts and colors are unchanged
  -- (most bands, most frames): the whole grid costs a fraction to rebuild.
  local st = ctx.state
  local geom = string.format("%d|%.3f|%.3f|%.3f|%s|%s", k, bw, H, radius, base, tostring(showPeaks))
  if st.gridGeom ~= geom or st.gridCols ~= cols or st.gridTracks ~= tracks or st.gridPeak ~= peakCol then
    st.gridGeom, st.gridCols, st.gridTracks, st.gridPeak = geom, cols, tracks, peakCol
    st.gridCache = {}
  end
  local cache = st.gridCache
  for i = 1, n do
    local v = values[i]
    local lit = floor(v * k + 0.5)
    lit = if lit < minLit then minLit elseif lit > k then k else lit
    local pk = 0
    if showPeaks then
      pk = floor(peaks[i] * k + 0.5)
      pk = if pk > k then k else pk
    end
    if center then
      -- Keep the lit run symmetric: its parity must match k.
      if lit % 2 ~= k % 2 then
        lit = min(k, lit + 1)
      end
      if pk % 2 ~= k % 2 then
        pk = min(k, pk + 1)
      end
    end
    local sig = lit * 1000 + pk
    local hit = cache[i]
    if hit ~= nil and hit.sig == sig then
      colsOut[i] = hit.node
      continue
    end
    local litCol = if lv then nil else cols[i]
    local trackCol = if tracks == nil then CLEAR elseif lv then nil else tracks[i]
    local cells = table.create(k)
    for t = 1, k do
      -- `pos` is the cell's distance from the baseline (1 = adjacent).
      local pos
      if center then
        pos = abs(t - half) * 2 + 1
      elseif top then
        pos = t
      else
        pos = k - t + 1
      end
      local fill
      if pos <= lit then
        fill = litCol or cols[(pos / k * LV + 0.5) // 1 + 1]
      elseif pk > lit and pos > pk - peakSpan and pos <= pk then
        fill = peakCol or litCol or cols[(pos / k * LV + 0.5) // 1 + 1]
      else
        fill = trackCol or tracks[(pos / k * LV + 0.5) // 1 + 1]
      end
      cells[t] = {
        type = "box",
        props = { key = kc[t], width = cw, height = chh, fill = fill, radius = radius },
        children = NO_CHILDREN,
      }
    end
    local node = {
      type = "column",
      props = { key = kk[i], width = bw, height = H, gap = vgap, align = "center" },
      children = cells,
    }
    cache[i] = { sig = sig, node = node }
    colsOut[i] = node
  end
  local total = n * bw + (n - 1) * gap
  local out = ctx.out
  out[#out + 1] = {
    kind = "node",
    key = if round then "matrix" else "blocks",
    cx = x0 + total / 2,
    cy = H / 2,
    w = total,
    h = H,
    node = { type = "row", props = { gap = gap, align = "start" }, children = colsOut },
  }
end

function S.blocks(ctx)
  cellGrid(ctx, false)
end

function S.dot_matrix(ctx)
  cellGrid(ctx, true)
end

-- Line / filled area through ui.graph, which evaluates its curve per pixel
-- on the GPU (smooth at any size) and fades its fill from the baseline up.
-- Its quirks are compensated here:
--  * It keeps a padding band of graphPad() of its height above and below the
--    plot, so the graph is made taller by that much and clipped: the plot
--    range lands exactly on the baseline and the far edge.
--  * It hides the first three samples and ends on an extrapolated lead sample
--    (scroll protocol), so three leading samples are prepended: band 1 sits
--    on the left edge and the last band on the right edge.
--  * It takes one color. Color modes cut it into scissor-clipped tiles, each
--    a copy of the graph in its own color: columns for gradient / rainbow /
--    alternate, rows for "by level", with enough of them that neighbouring
--    colors differ by less than one 8-bit step on screen. Scissor clips are
--    whole pixels, so tiles meet without seams.
--  * Its shader evaluates the curve about 20 times per pixel and series, over
--    the whole node. So the curve is cut into vertical strips and each
--    strip's tiles cover only the height its stretch of curve reaches (line
--    width and anti-aliasing included): the empty rest is never shaded. Each
--    strip's graph also gets only the samples that stretch reads (the cubic
--    reads two neighbours each side), placed so it draws exactly the curve
--    the full graph would.
local GRAPH_EPS = 0.0001
local GRAPH_AA = 0.5 -- the graph shader's anti-aliasing width (px)
local H10 = 4 / 27 -- max of the Hermite basis h10 on [0, 1] (tangent overshoot)
local SOLID_STRIPS = 8

-- The shader's padding (fraction of the graph height) for a graph gPx tall
-- with a line lwPx wide.
function S.graphPad(gPx, lwPx)
  local linePad = (lwPx * 0.5 + GRAPH_AA * 2 + 1) / max(gPx, 1)
  return min(0.18, max(linePad + 0.04, 0.06))
end

-- Graph height and padding so that its plot range is exactly `gh` units.
function S.graphFit(gh, lw, pxPerUnit)
  local pad = 0.06
  for _ = 1, 4 do
    local g = gh / (1 - 2 * pad)
    pad = S.graphPad(g * pxPerUnit, lw * pxPerUnit)
  end
  return gh / (1 - 2 * pad), pad
end

-- Value bounds of every segment of graph series `o` and, if given, `p`
-- (o[1..3] hidden leading samples, o[4] = band 1 .. o[n + 3] = band n) as
-- the shader draws them: a cubic Hermite with tangents (y2 - y0) / 4, ending
-- on the host's extrapolated lead. Segment s spans bands s .. s + 1; lo / hi
-- bound both series, do[s] / dp[s] bound each one's |dy/du| (u = band index).
-- Strip k (of `strips`, each `su` segments wide) gets the union of its
-- segments' bounds in stripLo[k] / stripHi[k], in the same pass.
local function segmentBounds(o, p, n, lo, hi, do_, dp, su, strips, stripLo, stripHi)
  local lastO = o[n + 3]
  local leadO = math.clamp(lastO + (lastO - o[n + 2]) * 0.5, 0, 1)
  local leadP = 0
  if p ~= nil then
    local lastP = p[n + 3]
    leadP = math.clamp(lastP + (lastP - p[n + 2]) * 0.5, 0, 1)
  end
  -- Unrolled 4x (the host meters loop back-edges); same body in each block.
  local last = n - 1
  local last4 = last - last % 4
  for s0 = 0, last4 - 1, 4 do
    do
      local s = s0 + 1
      local y0, y1, y2 = o[s + 2], o[s + 3], o[s + 4]
      local y3 = if s < n - 1 then o[s + 5] else leadO
      local m1, m2 = abs(y2 - y0) * 0.25, abs(y3 - y1) * 0.25
      local over = (m1 + m2) * H10
      local a, b = y1, y2
      if a > b then
        a, b = b, a
      end
      do_[s] = 1.5 * (b - a) + m1 + m2
      a -= over
      b += over
      if p ~= nil then
        y0, y1, y2 = p[s + 2], p[s + 3], p[s + 4]
        y3 = if s < n - 1 then p[s + 5] else leadP
        m1, m2 = abs(y2 - y0) * 0.25, abs(y3 - y1) * 0.25
        over = (m1 + m2) * H10
        local c, d = y1, y2
        if c > d then
          c, d = d, c
        end
        dp[s] = 1.5 * (d - c) + m1 + m2
        c -= over
        d += over
        if c < a then
          a = c
        end
        if d > b then
          b = d
        end
      end
      lo[s], hi[s] = a, b
      -- Strips overlapping segment s (u = s - 1 .. s): usually one or two.
      local k1 = floor((s - 1) / su) + 1
      local k2 = math.ceil(s / su)
      if k2 > strips then
        k2 = strips
      end
      if a < stripLo[k1] then
        stripLo[k1] = a
      end
      if b > stripHi[k1] then
        stripHi[k1] = b
      end
      if k2 > k1 then
        if a < stripLo[k2] then
          stripLo[k2] = a
        end
        if b > stripHi[k2] then
          stripHi[k2] = b
        end
        for k = k1 + 1, k2 - 1 do -- strips narrower than a segment
          if a < stripLo[k] then
            stripLo[k] = a
          end
          if b > stripHi[k] then
            stripHi[k] = b
          end
        end
      end
    end
    do
      local s = s0 + 2
      local y0, y1, y2 = o[s + 2], o[s + 3], o[s + 4]
      local y3 = if s < n - 1 then o[s + 5] else leadO
      local m1, m2 = abs(y2 - y0) * 0.25, abs(y3 - y1) * 0.25
      local over = (m1 + m2) * H10
      local a, b = y1, y2
      if a > b then
        a, b = b, a
      end
      do_[s] = 1.5 * (b - a) + m1 + m2
      a -= over
      b += over
      if p ~= nil then
        y0, y1, y2 = p[s + 2], p[s + 3], p[s + 4]
        y3 = if s < n - 1 then p[s + 5] else leadP
        m1, m2 = abs(y2 - y0) * 0.25, abs(y3 - y1) * 0.25
        over = (m1 + m2) * H10
        local c, d = y1, y2
        if c > d then
          c, d = d, c
        end
        dp[s] = 1.5 * (d - c) + m1 + m2
        c -= over
        d += over
        if c < a then
          a = c
        end
        if d > b then
          b = d
        end
      end
      lo[s], hi[s] = a, b
      -- Strips overlapping segment s (u = s - 1 .. s): usually one or two.
      local k1 = floor((s - 1) / su) + 1
      local k2 = math.ceil(s / su)
      if k2 > strips then
        k2 = strips
      end
      if a < stripLo[k1] then
        stripLo[k1] = a
      end
      if b > stripHi[k1] then
        stripHi[k1] = b
      end
      if k2 > k1 then
        if a < stripLo[k2] then
          stripLo[k2] = a
        end
        if b > stripHi[k2] then
          stripHi[k2] = b
        end
        for k = k1 + 1, k2 - 1 do -- strips narrower than a segment
          if a < stripLo[k] then
            stripLo[k] = a
          end
          if b > stripHi[k] then
            stripHi[k] = b
          end
        end
      end
    end
    do
      local s = s0 + 3
      local y0, y1, y2 = o[s + 2], o[s + 3], o[s + 4]
      local y3 = if s < n - 1 then o[s + 5] else leadO
      local m1, m2 = abs(y2 - y0) * 0.25, abs(y3 - y1) * 0.25
      local over = (m1 + m2) * H10
      local a, b = y1, y2
      if a > b then
        a, b = b, a
      end
      do_[s] = 1.5 * (b - a) + m1 + m2
      a -= over
      b += over
      if p ~= nil then
        y0, y1, y2 = p[s + 2], p[s + 3], p[s + 4]
        y3 = if s < n - 1 then p[s + 5] else leadP
        m1, m2 = abs(y2 - y0) * 0.25, abs(y3 - y1) * 0.25
        over = (m1 + m2) * H10
        local c, d = y1, y2
        if c > d then
          c, d = d, c
        end
        dp[s] = 1.5 * (d - c) + m1 + m2
        c -= over
        d += over
        if c < a then
          a = c
        end
        if d > b then
          b = d
        end
      end
      lo[s], hi[s] = a, b
      -- Strips overlapping segment s (u = s - 1 .. s): usually one or two.
      local k1 = floor((s - 1) / su) + 1
      local k2 = math.ceil(s / su)
      if k2 > strips then
        k2 = strips
      end
      if a < stripLo[k1] then
        stripLo[k1] = a
      end
      if b > stripHi[k1] then
        stripHi[k1] = b
      end
      if k2 > k1 then
        if a < stripLo[k2] then
          stripLo[k2] = a
        end
        if b > stripHi[k2] then
          stripHi[k2] = b
        end
        for k = k1 + 1, k2 - 1 do -- strips narrower than a segment
          if a < stripLo[k] then
            stripLo[k] = a
          end
          if b > stripHi[k] then
            stripHi[k] = b
          end
        end
      end
    end
    do
      local s = s0 + 4
      local y0, y1, y2 = o[s + 2], o[s + 3], o[s + 4]
      local y3 = if s < n - 1 then o[s + 5] else leadO
      local m1, m2 = abs(y2 - y0) * 0.25, abs(y3 - y1) * 0.25
      local over = (m1 + m2) * H10
      local a, b = y1, y2
      if a > b then
        a, b = b, a
      end
      do_[s] = 1.5 * (b - a) + m1 + m2
      a -= over
      b += over
      if p ~= nil then
        y0, y1, y2 = p[s + 2], p[s + 3], p[s + 4]
        y3 = if s < n - 1 then p[s + 5] else leadP
        m1, m2 = abs(y2 - y0) * 0.25, abs(y3 - y1) * 0.25
        over = (m1 + m2) * H10
        local c, d = y1, y2
        if c > d then
          c, d = d, c
        end
        dp[s] = 1.5 * (d - c) + m1 + m2
        c -= over
        d += over
        if c < a then
          a = c
        end
        if d > b then
          b = d
        end
      end
      lo[s], hi[s] = a, b
      -- Strips overlapping segment s (u = s - 1 .. s): usually one or two.
      local k1 = floor((s - 1) / su) + 1
      local k2 = math.ceil(s / su)
      if k2 > strips then
        k2 = strips
      end
      if a < stripLo[k1] then
        stripLo[k1] = a
      end
      if b > stripHi[k1] then
        stripHi[k1] = b
      end
      if k2 > k1 then
        if a < stripLo[k2] then
          stripLo[k2] = a
        end
        if b > stripHi[k2] then
          stripHi[k2] = b
        end
        for k = k1 + 1, k2 - 1 do -- strips narrower than a segment
          if a < stripLo[k] then
            stripLo[k] = a
          end
          if b > stripHi[k] then
            stripHi[k] = b
          end
        end
      end
    end
  end
  for s = last4 + 1, last do
    local y0, y1, y2 = o[s + 2], o[s + 3], o[s + 4]
    local y3 = if s < n - 1 then o[s + 5] else leadO
    local m1, m2 = abs(y2 - y0) * 0.25, abs(y3 - y1) * 0.25
    local over = (m1 + m2) * H10
    local a, b = y1, y2
    if a > b then
      a, b = b, a
    end
    do_[s] = 1.5 * (b - a) + m1 + m2
    a -= over
    b += over
    if p ~= nil then
      y0, y1, y2 = p[s + 2], p[s + 3], p[s + 4]
      y3 = if s < n - 1 then p[s + 5] else leadP
      m1, m2 = abs(y2 - y0) * 0.25, abs(y3 - y1) * 0.25
      over = (m1 + m2) * H10
      local c, d = y1, y2
      if c > d then
        c, d = d, c
      end
      dp[s] = 1.5 * (d - c) + m1 + m2
      c -= over
      d += over
      if c < a then
        a = c
      end
      if d > b then
        b = d
      end
    end
    lo[s], hi[s] = a, b
    -- Strips overlapping segment s (u = s - 1 .. s): usually one or two.
    local k1 = floor((s - 1) / su) + 1
    local k2 = math.ceil(s / su)
    if k1 > strips then
      k1 = strips
    end
    if k2 > strips then
      k2 = strips
    end
    if a < stripLo[k1] then
      stripLo[k1] = a
    end
    if b > stripHi[k1] then
      stripHi[k1] = b
    end
    if k2 > k1 then
      if a < stripLo[k2] then
        stripLo[k2] = a
      end
      if b > stripHi[k2] then
        stripHi[k2] = b
      end
      for k = k1 + 1, k2 - 1 do -- strips narrower than a segment
        if a < stripLo[k] then
          stripLo[k] = a
        end
        if b > stripHi[k] then
          stripHi[k] = b
        end
      end
    end
  end
end

-- For "by level" rows: first[r] / last[r] = the first and last segment whose
-- drawn line (bounds widened by `margin`) reaches color row r of `rows`, or
-- 0. Row r covers values (r - 1) / rowK .. r / rowK (the top row also takes
-- the rest up to 1). The curve is continuous, so the rows reached by segments 1 .. s always
-- form one interval [A, B]; each pass only assigns rows as that interval
-- grows (any gap is filled, which is merely conservative). Two passes of n
-- segments plus `rows` assignments, unrolled 4x (the host meters loop
-- back-edges).
local function rowExtents(segLo, segHi, n, rows, rowK, margin, filled, first, last)
  local A, B = rows + 1, 0
  local count = n - 1 - (1) + 1
  local c4 = count - count % 4
  for j0 = 0, c4 - 1, 4 do
    do
      local s = 1 + j0 + 0
      local a = if filled then 1 else floor((segLo[s] - margin) * rowK) + 1
      local b = math.ceil((segHi[s] + margin) * rowK)
      if a < 1 then
        a = 1
      end
      if b > rows then
        b = rows
      end
      if a <= b then
        if A > B then
          for r = a, b do
            first[r] = s
          end
          A, B = a, b
        else
          if a < A then
            for r = a, A - 1 do
              first[r] = s
            end
            A = a
          end
          if b > B then
            for r = B + 1, b do
              first[r] = s
            end
            B = b
          end
        end
      end
    end
    do
      local s = 1 + j0 + 1
      local a = if filled then 1 else floor((segLo[s] - margin) * rowK) + 1
      local b = math.ceil((segHi[s] + margin) * rowK)
      if a < 1 then
        a = 1
      end
      if b > rows then
        b = rows
      end
      if a <= b then
        if A > B then
          for r = a, b do
            first[r] = s
          end
          A, B = a, b
        else
          if a < A then
            for r = a, A - 1 do
              first[r] = s
            end
            A = a
          end
          if b > B then
            for r = B + 1, b do
              first[r] = s
            end
            B = b
          end
        end
      end
    end
    do
      local s = 1 + j0 + 2
      local a = if filled then 1 else floor((segLo[s] - margin) * rowK) + 1
      local b = math.ceil((segHi[s] + margin) * rowK)
      if a < 1 then
        a = 1
      end
      if b > rows then
        b = rows
      end
      if a <= b then
        if A > B then
          for r = a, b do
            first[r] = s
          end
          A, B = a, b
        else
          if a < A then
            for r = a, A - 1 do
              first[r] = s
            end
            A = a
          end
          if b > B then
            for r = B + 1, b do
              first[r] = s
            end
            B = b
          end
        end
      end
    end
    do
      local s = 1 + j0 + 3
      local a = if filled then 1 else floor((segLo[s] - margin) * rowK) + 1
      local b = math.ceil((segHi[s] + margin) * rowK)
      if a < 1 then
        a = 1
      end
      if b > rows then
        b = rows
      end
      if a <= b then
        if A > B then
          for r = a, b do
            first[r] = s
          end
          A, B = a, b
        else
          if a < A then
            for r = a, A - 1 do
              first[r] = s
            end
            A = a
          end
          if b > B then
            for r = B + 1, b do
              first[r] = s
            end
            B = b
          end
        end
      end
    end
  end
  for s = 1 + c4, n - 1 do
    local a = if filled then 1 else floor((segLo[s] - margin) * rowK) + 1
    local b = math.ceil((segHi[s] + margin) * rowK)
    if a < 1 then
      a = 1
    end
    if b > rows then
      b = rows
    end
    if a <= b then
      if A > B then
        for r = a, b do
          first[r] = s
        end
        A, B = a, b
      else
        if a < A then
          for r = a, A - 1 do
            first[r] = s
          end
          A = a
        end
        if b > B then
          for r = B + 1, b do
            first[r] = s
          end
          B = b
        end
      end
    end
  end
  A, B = rows + 1, 0
  do
    local count = n - 1 - (1) + 1
    local c4 = count - count % 4
    for j0 = 0, c4 - 1, 4 do
      do
        local s = n - 1 - j0 - 0
        local a = if filled then 1 else floor((segLo[s] - margin) * rowK) + 1
        local b = math.ceil((segHi[s] + margin) * rowK)
        if a < 1 then
          a = 1
        end
        if b > rows then
          b = rows
        end
        if a <= b then
          if A > B then
            for r = a, b do
              last[r] = s
            end
            A, B = a, b
          else
            if a < A then
              for r = a, A - 1 do
                last[r] = s
              end
              A = a
            end
            if b > B then
              for r = B + 1, b do
                last[r] = s
              end
              B = b
            end
          end
        end
      end
      do
        local s = n - 1 - j0 - 1
        local a = if filled then 1 else floor((segLo[s] - margin) * rowK) + 1
        local b = math.ceil((segHi[s] + margin) * rowK)
        if a < 1 then
          a = 1
        end
        if b > rows then
          b = rows
        end
        if a <= b then
          if A > B then
            for r = a, b do
              last[r] = s
            end
            A, B = a, b
          else
            if a < A then
              for r = a, A - 1 do
                last[r] = s
              end
              A = a
            end
            if b > B then
              for r = B + 1, b do
                last[r] = s
              end
              B = b
            end
          end
        end
      end
      do
        local s = n - 1 - j0 - 2
        local a = if filled then 1 else floor((segLo[s] - margin) * rowK) + 1
        local b = math.ceil((segHi[s] + margin) * rowK)
        if a < 1 then
          a = 1
        end
        if b > rows then
          b = rows
        end
        if a <= b then
          if A > B then
            for r = a, b do
              last[r] = s
            end
            A, B = a, b
          else
            if a < A then
              for r = a, A - 1 do
                last[r] = s
              end
              A = a
            end
            if b > B then
              for r = B + 1, b do
                last[r] = s
              end
              B = b
            end
          end
        end
      end
      do
        local s = n - 1 - j0 - 3
        local a = if filled then 1 else floor((segLo[s] - margin) * rowK) + 1
        local b = math.ceil((segHi[s] + margin) * rowK)
        if a < 1 then
          a = 1
        end
        if b > rows then
          b = rows
        end
        if a <= b then
          if A > B then
            for r = a, b do
              last[r] = s
            end
            A, B = a, b
          else
            if a < A then
              for r = a, A - 1 do
                last[r] = s
              end
              A = a
            end
            if b > B then
              for r = B + 1, b do
                last[r] = s
              end
              B = b
            end
          end
        end
      end
    end
    for s = n - 1 - c4, 1, -1 do
      local a = if filled then 1 else floor((segLo[s] - margin) * rowK) + 1
      local b = math.ceil((segHi[s] + margin) * rowK)
      if a < 1 then
        a = 1
      end
      if b > rows then
        b = rows
      end
      if a <= b then
        if A > B then
          for r = a, b do
            last[r] = s
          end
          A, B = a, b
        else
          if a < A then
            for r = a, A - 1 do
              last[r] = s
            end
            A = a
          end
          if b > B then
            for r = B + 1, b do
              last[r] = s
            end
            B = b
          end
        end
      end
    end
  end
end

local function curveShape(ctx, fillOpacity)
  local c, pal, W, H, out = ctx.c, ctx.pal, ctx.W, ctx.H, ctx.out
  local values, peaks = ctx.values, ctx.peaks
  local n = #values
  local ppu = ctx.pxPerUnit or 1.5
  -- Screen px per unit for the shaded margins; unknown (bar) assumes 1.
  local marginPpu = if ctx.pxPerUnitKnown then ppu else min(ppu, 1)
  local lw = max(0.5, c.lineWidth)
  local showPeaks = c.showPeaks
  local color2 = if showPeaks then pal:peak(1, 1, 1) else nil
  local filled = fillOpacity > 0
  local mode = pal.mode
  local byLevel = mode == "level"
  -- Color slices for under one 8-bit step between neighbours: the colors'
  -- spread times how strongly they show (fill, or the thin line).
  local strength = max(fillOpacity, 0.35) * pal.alpha
  local slices = 1
  if mode == "palette" then
    slices = math.clamp(n, 1, 128)
  elseif mode ~= "solid" then
    slices = math.clamp(math.ceil(pal:spread() * strength * 1.25), 2, 96)
  end
  -- Vertical strips: one per color column, else a few for culling.
  local rows, strips = 1, slices
  if byLevel then
    -- One tile per color row reached, clipped to where the curve crosses it
    -- (graph count is what costs CPU on the host, so no strips x rows grid).
    rows = slices
    strips = 1
  elseif mode == "solid" then
    strips = SOLID_STRIPS
  end
  if n < 2 then
    strips = 1
  elseif slices == 1 or byLevel then
    strips = min(strips, n - 1)
  end
  local st = ctx.state
  local segLo, segHi = st.segLo or {}, st.segHi or {}
  local dv, dp = st.dv or {}, st.dp or {}
  st.segLo, st.segHi, st.dv, st.dp = segLo, segHi, dv, dp

  local function series(src, reverse, gh)
    local lift = if c.minSize > 0 then min(0.5, c.minSize / gh) else 0
    local o = table.create(n + 3)
    if lift == 0 and not reverse then
      table.move(src, 1, n, 4, o) -- one call instead of a metered loop
    else
      local keep = 1 - lift
      local n4 = n - n % 4
      if reverse then
        for i = 1, n4, 4 do -- unrolled: the host meters loop back-edges
          o[i + 3] = lift + src[n - i + 1] * keep
          o[i + 4] = lift + src[n - i] * keep
          o[i + 5] = lift + src[n - i - 1] * keep
          o[i + 6] = lift + src[n - i - 2] * keep
        end
        for i = n4 + 1, n do
          o[i + 3] = lift + src[n - i + 1] * keep
        end
      else
        for i = 1, n4, 4 do
          o[i + 3] = lift + src[i] * keep
          o[i + 4] = lift + src[i + 1] * keep
          o[i + 5] = lift + src[i + 2] * keep
          o[i + 6] = lift + src[i + 3] * keep
        end
        for i = n4 + 1, n do
          o[i + 3] = lift + src[i] * keep
        end
      end
    end
    -- Hidden leading samples: a linear continuation, for the left tangent.
    local lead = math.clamp(2 * o[4] - (o[5] or o[4]), 0, 1)
    o[1], o[2], o[3] = lead, lead, lead
    return o
  end

  local function half(prefix, gcx, gcy, gw, gh, flipped)
    local vals = series(values, flipped, gh)
    local pks = if showPeaks then series(peaks, flipped, gh) else nil
    local fitKey = gh * 1e6 + lw * 1e3 + ppu
    if st.fitKey ~= fitKey then
      st.fitKey = fitKey
      st.fitG, st.fitPad = S.graphFit(gh, lw, ppu)
    end
    local G, pad = st.fitG, st.fitPad
    local spacing = if n > 1 then gw / (n - 1) else gw
    -- Node keys change whenever a tile's data size could: the host mis-samples
    -- a graph whose series shrinks, so a key always keeps one size.
    local reachKey = floor(3 / (spacing * marginPpu) * 1000)
    local keySig = string.format("%s%s%d_%d_%d", prefix, if pks then "p" else "", n, strips, reachKey)
    local keys = KEYS[keySig]
    -- Tiles that meet (rows, strips) are sized in whole screen pixels when
    -- the scale is known: the host rounds clip edges outwards (floor / ceil),
    -- so tiles meeting mid-pixel would both paint the shared pixel row and
    -- leave a bright seam. The half's edges sit on pixels already; the last
    -- strip / top row takes the remainder.
    local pxq = if ctx.pxPerUnitKnown then ppu else nil
    local sw = gw / strips
    if pxq ~= nil and strips > 1 and floor(gw * pxq / strips) >= 1 then
      sw = floor(gw * pxq / strips) / pxq
    end
    local sh = gh / rows
    if pxq ~= nil and rows > 1 and floor(gh * pxq / rows) >= 1 then
      sh = floor(gh * pxq / rows) / pxq
    end
    local rowK = gh / sh
    -- Edges where tiles meet are pulled in by a fiftieth of a pixel, so the
    -- host's outward rounding can't take a shared pixel row twice when float
    -- error puts an edge a hair past the pixel boundary.
    local inset = if pxq ~= nil then 0.02 / pxq else 0
    -- Strips in band units (u = band index - 1, 0 .. n - 1).
    local su = if n > 1 then sw / spacing else 1
    -- The shader reads the curve up to 2 px either side of a pixel.
    local reach = 3 / (spacing * marginPpu)
    local margin = (lw * 0.5 + (GRAPH_AA * 2 * 1.42 + 1) / marginPpu) / gh
    -- Colors from the palette's cached arrays (one call, not one per tile).
    local cols = nil
    if byLevel then
      cols = pal:colors(1)
    elseif mode == "palette" then
      cols = pal:colors(n)
    elseif slices > 1 then
      cols = pal:colors(strips)
    end
    local solidColor = if cols == nil then pal:primary() else nil
    local dbg = ctx.debug
    if dbg then
      dbg[prefix] = {
        strips = strips,
        sw = sw,
        gw = gw,
        gh = gh,
        spacing = spacing,
        vals = vals,
        pks = pks,
        lw = lw,
        ppu = marginPpu,
        filled = filled,
      }
    end
    local stripLo, stripHi
    if n > 1 then
      stripLo, stripHi = table.create(strips, math.huge), table.create(strips, -math.huge)
      segmentBounds(vals, pks, n, segLo, segHi, dv, dp, su, strips, stripLo, stripHi)
    end
    if byLevel and n > 1 then
      -- Each row's tile spans the segments that reach it, plus the line's
      -- half width and anti-aliasing sideways.
      local first, last = table.create(rows, 0), table.create(rows, 0)
      rowExtents(segLo, segHi, n, rows, rowK, margin, filled, first, last)
      local mx = lw * 0.5 + 3 / marginPpu
      for r = 1, rows do
        local f = first[r]
        if f == 0 then
          continue
        end
        local x0 = max(0, (f - 1) * spacing - mx)
        local x1 = min(gw, last[r] * spacing + mx)
        local tw = x1 - x0
        -- The full series: a row's reach changes every frame, and the host
        -- mis-samples a graph whose data shrinks (it keeps the larger texture
        -- but indexes it by the new width), so a row tile's data size must
        -- never change.
        local kLo, kHi = 0, n + 2
        local wv, wp = vals, pks
        local ly = (if r < rows then gh - r * sh else 0) + inset
        local th = (if r < rows then sh else gh - (rows - 1) * sh) - 2 * inset
        local lcx, lcy = x0 + tw / 2, ly + th / 2
        local cx, cy
        if flipped then
          cx, cy = gcx + gw / 2 - lcx, gcy + gh / 2 - lcy
        else
          cx, cy = gcx - gw / 2 + lcx, gcy - gh / 2 + lcy
        end
        out[#out + 1] = {
          kind = "node",
          dbg = if dbg then { half = prefix, kLo = kLo, kHi = kHi, x0 = x0, x1 = x1, ly = ly, th = th } else nil,
          key = keys[r],
          cx = cx,
          cy = cy,
          w = tw,
          h = th,
          rot = if flipped then 180 else nil,
          node = {
            type = "column",
            props = { clip = true, align = "start" },
            children = {
              {
                type = "row",
                props = { width = GRAPH_EPS, height = G, align = "start" },
                children = {
                  {
                    type = "graph",
                    props = {
                      width = (kHi - kLo - 2) * spacing,
                      height = G,
                      values = wv,
                      values2 = wp,
                      color = cols[((r - 0.5) / rows * LV + 0.5) // 1 + 1],
                      color2 = color2,
                      lineWidth = lw,
                      fillOpacity = fillOpacity,
                      translateX = kLo * spacing - x0,
                      translateY = -ly - pad * G,
                    },
                    children = NO_CHILDREN,
                  },
                },
              },
            },
          },
        }
      end
      return
    end
    -- Windows span at least ~8 segments (or one strip).
    local perWindow = max(1, math.ceil(8 / su))
    local winGroup, kLo, kHi, wv, wp = -1, 0, n + 2, vals, pks
    for k = 1, strips do
      local lo, hi = 0, 1
      local ua, ub = (k - 1) * su, if k < strips then k * su else n - 1
      if n > 1 then
        local s1 = math.clamp(floor(ua) + 1, 1, n - 1)
        local s2 = math.clamp(math.ceil(ub), s1, n - 1)
        lo, hi = stripLo[k], stripHi[k]
        if s1 > 1 and ua - reach < s1 - 1 then
          local y, e = vals[s1 + 3], dv[s1 - 1] * reach
          if y - e < lo then
            lo = y - e
          end
          if y + e > hi then
            hi = y + e
          end
          if pks then
            local y, e = pks[s1 + 3], dp[s1 - 1] * reach
            if y - e < lo then
              lo = y - e
            end
            if y + e > hi then
              hi = y + e
            end
          end
        end
        if s2 < n - 1 and ub + reach > s2 then
          local y, e = vals[s2 + 1 + 3], dv[s2 + 1] * reach
          if y - e < lo then
            lo = y - e
          end
          if y + e > hi then
            hi = y + e
          end
          if pks then
            local y, e = pks[s2 + 1 + 3], dp[s2 + 1] * reach
            if y - e < lo then
              lo = y - e
            end
            if y + e > hi then
              hi = y + e
            end
          end
        end
        lo = if filled then 0 else max(0, lo - margin)
        hi = min(1, hi + margin)
      end
      if hi <= lo then
        continue
      end
      -- The samples this strip reads: graph texture indices kLo .. kHi
      -- (0-based; index 3 is band 1). Up to the last band the host appends
      -- the same extrapolated lead the full graph has. Narrow strips share
      -- one window per group of `perWindow` strips (fewer copies to make).
      local g = (k - 1) // perWindow
      if g ~= winGroup then
        winGroup = g
        kLo, kHi = 0, n + 2
        if n > 1 then
          local ga = g * perWindow * su
          local gb = if (g + 1) * perWindow < strips then (g + 1) * perWindow * su else n - 1
          kLo = max(0, floor(ga - reach + 3) - 3)
          kHi = min(n + 2, floor(gb + reach + 3) + 2)
        end
        wv, wp = vals, pks
        if kLo > 0 or kHi < n + 2 then
          wv = table.move(vals, kLo + 1, kHi + 1, 1, table.create(kHi - kLo + 1))
          if pks then
            wp = table.move(pks, kLo + 1, kHi + 1, 1, table.create(kHi - kLo + 1))
          end
        end
      end
      local gx = kLo * spacing -- graph left edge, half-local
      local gwide = (kHi - kLo - 2) * spacing
      local lx = (k - 1) * sw + inset
      local tw = (if k < strips then sw else gw - (k - 1) * sw) - 2 * inset
      local r1, r2 = 1, 1
      if byLevel then
        r1 = math.clamp(floor(lo * rows) + 1, 1, rows)
        r2 = math.clamp(math.ceil(hi * rows), r1, rows)
      end
      for r = r1, r2 do
        local ly, th, color
        if byLevel then
          -- Row r counted from the baseline, colored by its level.
          ly, th = gh - r * sh, sh
          color = cols[((r - 0.5) / rows * LV + 0.5) // 1 + 1]
        else
          ly, th = (1 - hi) * gh, (hi - lo) * gh
          if cols == nil then
            color = solidColor
          else
            local idx = if flipped then strips - k + 1 else k -- on-screen order
            color = cols[if mode == "palette" then math.ceil(idx * n / strips) else idx]
          end
        end
        local lcx, lcy = lx + tw / 2, ly + th / 2
        local cx, cy
        if flipped then
          cx, cy = gcx + gw / 2 - lcx, gcy + gh / 2 - lcy
        else
          cx, cy = gcx - gw / 2 + lcx, gcy - gh / 2 + lcy
        end
        out[#out + 1] = {
          kind = "node",
          dbg = if dbg then { half = prefix, kLo = kLo, kHi = kHi, x0 = lx, x1 = lx + tw, ly = ly, th = th } else nil,
          key = keys[(k - 1) * (rows + 1) + r],
          cx = cx,
          cy = cy,
          w = tw,
          h = th,
          rot = if flipped then 180 else nil,
          node = {
            type = "column",
            props = { clip = true, align = "start" },
            children = {
              {
                type = "row",
                props = { width = GRAPH_EPS, height = G, align = "start" },
                children = {
                  {
                    type = "graph",
                    props = {
                      width = gwide,
                      height = G,
                      values = wv,
                      values2 = wp,
                      color = color,
                      color2 = color2,
                      lineWidth = lw,
                      fillOpacity = fillOpacity,
                      translateX = gx - lx,
                      translateY = -ly - pad * G,
                    },
                    children = NO_CHILDREN,
                  },
                },
              },
            },
          },
        }
      end
    end
  end

  if c.baseline == "center" then
    half("cu", W / 2, H / 4, W, H / 2, false)
    half("cd", W / 2, H * 3 / 4, W, H / 2, true)
  elseif c.baseline == "top" then
    half("ct", W / 2, H / 2, W, H, true)
  else
    half("cb", W / 2, H / 2, W, H, false)
  end
end

function S.wave(ctx)
  curveShape(ctx, 0)
end

function S.area(ctx)
  curveShape(ctx, max(0.05, ctx.c.fillOpacity))
end

-- Text shapes size their font from the canvas. Monospace glyphs advance
-- about 0.6 em; a line is about 1.36 em tall (Noto Sans Mono, the usual
-- `monospace`), so 1.4 leaves a little slack. The text block is anchored to
-- the baseline by flex, so a font with other metrics only changes the gap at
-- the far edge, never at the baseline.
local CHAR_ADVANCE = 0.6
local LINE_HEIGHT = 1.4

-- Rows and font size that fill a w x h area with `cols` characters per row:
-- at least `minRows` rows, plus as many as the height allows.
local function textLayout(w, h, cols, minRows)
  local fs = w / (cols * CHAR_ADVANCE)
  local rows = max(minRows, floor(h / (fs * LINE_HEIGHT)))
  fs = max(4, min(fs, h / (rows * LINE_HEIGHT)))
  return fs, rows
end

-- A label anchored to the bottom edge of a w x h container (the baseline;
-- flipped containers are turned 180° into place).
local function anchoredLabel(out, key, cx, cy, w, h, rot, text, fs, color, font, rows)
  out[#out + 1] = {
    kind = "node",
    key = key,
    cx = cx,
    cy = cy,
    w = w,
    h = h,
    rot = rot,
    node = {
      type = "column",
      props = { justify = "end", align = "center" },
      children = {
        {
          type = "label",
          props = {
            key = "l",
            text = text,
            fontSize = fs,
            color = color,
            fontFamily = font,
            maxLines = rows,
            textAlign = "center",
            baseline = "textFixedHeight",
          },
          children = NO_CHILDREN,
        },
      },
    },
  }
end

local BLOCK_CHARS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

-- textMaps(rows, base)[r][q + 1]: the glyph row r (1 = baseline) shows for
-- a band q eighths of a row tall. Built once per row count.
local TEXT_MAPS = {}
textMaps = function(rows: number, baseChar: string)
  local key = rows .. baseChar
  local maps = TEXT_MAPS[key]
  if maps == nil then
    maps = table.create(rows)
    for r = 1, rows do
      local map = table.create(rows * 8 + 1)
      for q = 0, rows * 8 do
        local fill = q - (r - 1) * 8
        map[q + 1] = if fill <= 0
          then (if r == 1 then baseChar else " ")
          else BLOCK_CHARS[if fill > 8 then 8 else fill]
      end
      maps[r] = map
    end
    TEXT_MAPS[key] = maps
  end
  return maps
end

-- Terminal-style bars from Unicode block elements (▁▂▃▄▅▆▇█).
function S.text(ctx)
  local c, pal, n, W, H, out = ctx.c, ctx.pal, ctx.n, ctx.W, ctx.H, ctx.out
  local values = ctx.values
  local center = c.baseline == "center"
  local h = if center then H / 2 else H
  local fs, rows = textLayout(W, h, n, max(1, c.textRows))
  local baseChar = if c.minSize > 0 then BLOCK_CHARS[1] else " "
  local maps = textMaps(rows, baseChar)
  local maxQ = rows * 8
  local qs = table.create(n + 7, 1)
  -- Loops are unrolled: the host meters every loop back-edge (~0.4 us each),
  -- and this shape writes rows x bands glyphs per frame.
  local function build(reverse)
    for idx = 1, n do
      local q = floor(values[if reverse then n - idx + 1 else idx] * maxQ + 0.5)
      qs[idx] = (if q < 0 then 0 elseif q > maxQ then maxQ else q) + 1
    end
    local lines = table.create(rows)
    local chars = table.create(n + 7)
    for r = rows, 1, -1 do
      local map = maps[r]
      for idx = 1, n, 8 do
        chars[idx] = map[qs[idx]]
        chars[idx + 1] = map[qs[idx + 1]]
        chars[idx + 2] = map[qs[idx + 2]]
        chars[idx + 3] = map[qs[idx + 3]]
        chars[idx + 4] = map[qs[idx + 4]]
        chars[idx + 5] = map[qs[idx + 5]]
        chars[idx + 6] = map[qs[idx + 6]]
        chars[idx + 7] = map[qs[idx + 7]]
      end
      lines[rows - r + 1] = table.concat(chars, "", 1, n)
    end
    return table.concat(lines, "\n")
  end
  local color = pal:primary()
  if center then
    anchoredLabel(out, "tu", W / 2, H / 4, W, h, 180, build(true), fs, color, c.textFont, rows)
    anchoredLabel(out, "td", W / 2, H * 3 / 4, W, h, 0, build(false), fs, color, c.textFont, rows)
  elseif c.baseline == "top" then
    anchoredLabel(out, "t", W / 2, H / 2, W, H, 180, build(true), fs, color, c.textFont, rows)
  else
    anchoredLabel(out, "t", W / 2, H / 2, W, H, 0, build(false), fs, color, c.textFont, rows)
  end
end

-- Braille dots: each character packs 2 bands x 4 dot rows.
local BRAILLE_LEFT = { 0x01, 0x02, 0x04, 0x40 }
local BRAILLE_RIGHT = { 0x08, 0x10, 0x20, 0x80 }
local BRAILLE = {}
for b = 0, 255 do
  BRAILLE[b] = utf8.char(0x2800 + b)
end

function S.braille(ctx)
  local c, pal, n, W, H, out = ctx.c, ctx.pal, ctx.n, ctx.W, ctx.H, ctx.out
  local values = ctx.values
  local chars = math.ceil(n / 2)
  local fs, rows = textLayout(W, H, chars, max(1, c.textRows))
  local dotRows = rows * 4
  local minDot = if c.minSize > 0 then 1 else 0
  local base = c.baseline
  local mid = (dotRows + 1) / 2
  -- Per band: the lit dot-row range [lo, hi] counted from the top.
  local lo, hi = table.create(n + 1, 1), table.create(n + 1, 0)
  for i = 1, n do
    local k = floor(values[i] * dotRows + 0.5)
    k = if k < minDot then minDot elseif k > dotRows then dotRows else k
    if base == "top" then
      lo[i], hi[i] = 1, k
    elseif base == "center" then
      if k % 2 ~= dotRows % 2 then
        k = min(dotRows, k + 1)
      end
      lo[i], hi[i] = mid - (k - 1) / 2, mid + (k - 1) / 2
    else
      lo[i], hi[i] = dotRows - k + 1, dotRows
    end
  end
  local lines = table.create(rows)
  local line = table.create(chars)
  for cr = 1, rows do
    for ch = 1, chars do
      local bits = 0
      local li, ri = ch * 2 - 1, ch * 2
      for dr = 1, 4 do
        local gr = (cr - 1) * 4 + dr
        if gr >= lo[li] and gr <= hi[li] then
          bits += BRAILLE_LEFT[dr]
        end
        if ri <= n and gr >= lo[ri] and gr <= hi[ri] then
          bits += BRAILLE_RIGHT[dr]
        end
      end
      line[ch] = BRAILLE[bits]
    end
    lines[cr] = table.concat(line)
  end
  -- Top and center baselines are drawn by the dot pattern itself, so only a
  -- bottom baseline needs the block anchored; top anchors by turning 180°
  -- would mirror the dots, so center / top keep the block centered.
  local text = table.concat(lines, "\n")
  local color = pal:primary()
  if base == "bottom" then
    anchoredLabel(out, "br", W / 2, H / 2, W, H, 0, text, fs, color, c.textFont, rows)
  else
    out[#out + 1] = {
      kind = "node",
      key = "br",
      cx = W / 2,
      cy = H / 2,
      w = W,
      h = H,
      node = {
        type = "column",
        props = { justify = if base == "top" then "start" else "center", align = "center" },
        children = {
          {
            type = "label",
            props = {
              key = "l",
              text = text,
              fontSize = fs,
              color = color,
              fontFamily = c.textFont,
              maxLines = rows,
              textAlign = "center",
              baseline = "textFixedHeight",
            },
            children = NO_CHILDREN,
          },
        },
      },
    }
  end
end

-- Scrolling waterfall: one row of cells per history step, intensity as alpha.
function S.spectrogram(ctx)
  local c, pal, n, H = ctx.c, ctx.pal, ctx.n, ctx.H
  local values = ctx.values
  local st = ctx.state
  local rowsMax = max(2, min(c.history, floor(1400 / max(1, n))))
  st.rows = st.rows or {}
  local now = ctx.t
  local pushed = false
  if st.lastPush == nil or now - st.lastPush >= c.historyMs / 1000 or now < st.lastPush then
    st.lastPush = now
    local snap = table.create(n)
    for i = 1, n do
      snap[i] = (values[i] * 24 + 0.5) // 1
    end
    table.insert(st.rows, 1, snap)
    pushed = true
  end
  while #st.rows > rowsMax do
    table.remove(st.rows)
  end
  local out = ctx.out
  if not pushed and st.prim ~= nil and st.nodeN == n then
    ctx.unchanged = true
    out[#out + 1] = st.prim
    return
  end
  local bw, gap, x0 = columns(ctx)
  local rg = max(0, c.segmentGap)
  local rh = max(0.5, (H - (rowsMax - 1) * rg) / rowsMax)
  local radius = c.roundness * min(bw, rh) / 2
  -- Intensity is the cell's opacity (a number), so no per-intensity color
  -- strings are needed; "by level" mode also picks the color from the level.
  local cols, lv = pal:colors(n)
  local empty = if pal.trackAlpha > 0 then pal:colors(n, pal.trackAlpha) else nil
  local newestAtTop = c.baseline == "top"
  local kc, kr = KEYS.c, KEYS.r
  -- A snapshot's cells are built once, when it scrolls in, and reused while
  -- it scrolls down (rows keep positional keys, so the host updates them in
  -- place). Only a change of size or colors rebuilds them all.
  local function cellsFor(snap)
    local cells = table.create(n)
    for i = 1, n do
      local q = if snap then snap[i] or 0 else 0
      local fill, op
      if q <= 0 then
        fill = if empty then empty[if lv then 1 else i] else nil
        op = 1
      else
        fill = cols[if lv then q * (LV // 24) + 1 else i]
        op = if lv then 1 else 0.08 + 0.92 * q / 24
      end
      cells[i] = {
        type = "box",
        props = { key = kc[i], width = bw, height = rh, fill = fill, radius = radius, opacity = op },
        children = NO_CHILDREN,
      }
    end
    return cells
  end
  if st.cellW ~= bw or st.cellH ~= rh or st.cellR ~= radius or st.cellCols ~= cols or st.cellEmpty ~= empty then
    st.cellW, st.cellH, st.cellR, st.cellCols, st.cellEmpty = bw, rh, radius, cols, empty
    for _, snap in ipairs(st.rows) do
      snap.cells = nil
    end
    st.emptyCells = nil
  end
  local rowsNodes = table.create(rowsMax)
  for r = 1, rowsMax do
    local snap = st.rows[if newestAtTop then r else rowsMax - r + 1]
    local cells
    if snap ~= nil then
      cells = snap.cells
      if cells == nil then
        cells = cellsFor(snap)
        snap.cells = cells
      end
    else
      cells = st.emptyCells
      if cells == nil then
        cells = cellsFor(nil)
        st.emptyCells = cells
      end
    end
    rowsNodes[r] = { type = "row", props = { key = kr[r], gap = gap, align = "start" }, children = cells }
  end
  local total = n * bw + (n - 1) * gap
  local prim = {
    kind = "node",
    key = "sg",
    cx = x0 + total / 2,
    cy = H / 2,
    w = total,
    h = H,
    node = { type = "column", props = { gap = rg, align = "start" }, children = rowsNodes },
  }
  st.prim = prim
  st.nodeN = n
  out[#out + 1] = prim
end

-- Bass / mid / treble level meters.
function S.meter(ctx)
  local c, pal, W, H, out = ctx.c, ctx.pal, ctx.W, ctx.H, ctx.out
  local sp, spk = ctx.spectrum, ctx.spectrumPeaks
  local bands = {
    { Dsp.band(sp, 0, 0.15), Dsp.band(spk, 0, 0.15) },
    { Dsp.band(sp, 0.15, 0.55), Dsp.band(spk, 0.15, 0.55) },
    { Dsp.band(sp, 0.55, 1), Dsp.band(spk, 0.55, 1) },
  }
  local rg = max(1, c.spacing)
  local rh = max(1, (H - 2 * rg) / 3)
  local k = max(1, c.segments)
  local sgap = max(0, c.segmentGap)
  local base = c.baseline
  local cols, lv = pal:colors(3)
  local tracks = if pal.trackAlpha > 0 then pal:colors(3, pal.trackAlpha) else nil
  local peakCol = pal.peakToken ~= nil and pal:peak(1, 3, 1) or nil
  local round = c.roundness * 0.5
  for row = 1, 3 do
    local v, pv = bands[row][1], bands[row][2]
    local cy = (row - 1) * (rh + rg) + rh / 2
    local km = KEYS["m" .. row .. "_"]
    if k > 1 then
      local segW = max(0.5, (W - (k - 1) * sgap) / k)
      local lit = math.clamp(floor(v * k + 0.5), if c.minSize > 0 then 1 else 0, k)
      local pk = if c.showPeaks then math.clamp(floor(pv * k + 0.5), 0, k) else 0
      local r = round * min(segW, rh)
      for s = 1, k do
        -- `pos` counts segments away from the baseline.
        local pos
        if base == "center" then
          pos = floor(abs(s - (k + 1) / 2) * 2 + 1.5)
        elseif base == "top" then
          pos = k - s + 1
        else
          pos = s
        end
        local q = (pos / k * LV + 0.5) // 1 + 1
        local fill
        if pos <= lit then
          fill = if lv then cols[q] else cols[row]
        elseif pk > lit and pos == pk then
          fill = peakCol or (if lv then cols[q] else cols[row])
        elseif tracks ~= nil then
          fill = if lv then tracks[q] else tracks[row]
        end
        if fill ~= nil then
          out[#out + 1] = {
            kind = "box",
            key = km[s],
            cx = (s - 1) * (segW + sgap) + segW / 2,
            cy = cy,
            w = segW,
            h = rh,
            fill = fill,
            radius = r,
            glow = (pos <= lit) ~= false,
          }
        end
      end
    else
      local room = peakRoom(c)
      local span = max(1, W - room)
      local minS = min(c.minSize, span)
      local L = minS + v * (span - minS)
      if tracks ~= nil then
        out[#out + 1] = {
          kind = "box",
          key = km[0],
          cx = W / 2,
          cy = cy,
          w = W,
          h = rh,
          fill = tracks[if lv then LV1 else row],
          radius = round * min(W, rh),
          glow = false,
        }
      end
      local cx = if base == "bottom" then L / 2 elseif base == "top" then W - L / 2 else W / 2
      out[#out + 1] = {
        kind = "box",
        key = km[1],
        cx = cx,
        cy = cy,
        w = L,
        h = rh,
        fill = cols[if lv then (v * LV + 0.5) // 1 + 1 else row],
        radius = round * min(L, rh),
        glow = true,
      }
      if room > 0 then
        local pl = minS + pv * (span - minS)
        local pt = c.peakThickness
        local px = if base == "bottom" then pl + 1 + pt / 2 elseif base == "top" then W - pl - 1 - pt / 2 else W / 2
        if base == "center" then
          pt = min(pt, W)
        end
        out[#out + 1] = {
          kind = "box",
          key = km[2],
          cx = math.clamp(px, pt / 2, W - pt / 2),
          cy = cy,
          w = pt,
          h = rh,
          fill = peakCol or cols[if lv then LV1 else row],
          radius = 0,
          glow = true,
        }
      end
    end
  end
end

-- ── Radial shapes ───────────────────────────────────────────────────────────

local function radialFrame(ctx)
  local c, W, H = ctx.c, ctx.W, ctx.H
  local R = max(4, min(W, H) / 2 - 1 - c.glow * 0.5)
  local r0 = math.clamp(c.radialInner, 0, 0.95) * R
  local arc = math.clamp(c.radialArc, 10, 360)
  local start = c.radialRotation + ctx.t * c.spin
  return W / 2, H / 2, R, r0, arc, start
end

-- Radial extents for an element of width `bw`: the radius its outer corners
-- may reach (`edge`), the usable inner radius and the max lengths outward and
-- inward. `room` is reserved beyond the bar for peak caps.
local function radialReach(R, r0, bw, room)
  local edge = sqrt(max(1, R * R - (bw / 2) ^ 2)) - room
  r0 = min(r0, edge - 1)
  return edge, max(0, r0), max(1, edge - r0), max(0, r0 * 0.92 - room)
end

-- A faint circle (or arc) marking the inner radius.
local function baseRing(ctx, cx, cy, r, arc, start)
  local c = ctx.c
  if ctx.pal.trackAlpha <= 0 or r < 2 then
    return
  end
  local th = max(1, min(2, r * 0.08))
  local d = 2 * r + th
  local out = ctx.out
  out[#out + 1] = {
    kind = "ring",
    key = "base",
    cx = cx,
    cy = cy,
    w = d,
    h = d,
    rot = if arc >= 360 then start else start - arc / 2,
    progress = arc / 360,
    fill = ctx.pal:track(1, 1, 1),
    track = CLEAR,
    thickness = th,
  }
end

-- Bars around a circle pointing out, in, or both ways.
function S.radial(ctx)
  local c, pal, n, out = ctx.c, ctx.pal, ctx.n, ctx.out
  local values, peaks = ctx.values, ctx.peaks
  local cx, cy, R, r0, arc, start = radialFrame(ctx)
  local dir = c.radialDirection
  local pt = c.peakThickness
  local room = peakRoom(c)
  local refR = if dir == "in" then r0 * 0.7 else max(r0, (R - r0) * 0.3)
  local slot = arc * DEG * max(1, refR) / n
  local bw = if c.barWidth > 0 then c.barWidth else max(1, slot - c.spacing)
  bw = min(bw, R * 0.5)
  local _, r0b, outMax, inMax = radialReach(R, r0, bw, room)
  r0 = r0b
  local Lmax = if dir == "in" then inMax elseif dir == "both" then min(outMax, inMax) else outMax
  if Lmax < 1 then
    dir = "out" -- the inner radius leaves no room inward: fall back to outward
    Lmax = outMax
  end
  local minS = min(c.minSize, Lmax)
  local round = c.roundness * 0.5
  local cols, lv = pal:colors(n)
  local tracks = if c.barTracks then pal:colors(n, pal.trackAlpha) else nil
  local peakCol = pal.peakToken ~= nil and pal:peak(1, n, 1) or nil
  local kb, kt, kp, kq = KEYS.b, KEYS.t, KEYS.p, KEYS.q
  local pr = min(pt, bw) / 2 * c.roundness
  local step = arc / n
  local a0 = start - arc / 2 + step / 2
  baseRing(ctx, cx, cy, r0, arc, start)
  for i = 1, n do
    local v = values[i]
    local th = a0 + (i - 1) * step
    local s, co = sin(th * DEG), cos(th * DEG)
    local L = minS + v * (Lmax - minS)
    local len, rc = L, r0 + L / 2
    if dir == "both" then
      len, rc = 2 * L, r0
    elseif dir == "in" then
      rc = r0 - L / 2
    end
    if tracks ~= nil then
      local tl = if dir == "both" then 2 * Lmax else Lmax
      local tr = if dir == "both" then r0 elseif dir == "in" then r0 - Lmax / 2 else r0 + Lmax / 2
      out[#out + 1] = {
        kind = "box",
        key = kt[i],
        cx = cx + tr * s,
        cy = cy - tr * co,
        w = bw,
        h = tl,
        fill = tracks[if lv then LV1 else i],
        radius = round * min(bw, tl),
        rot = th,
        glow = false,
      }
    end
    out[#out + 1] = {
      kind = "box",
      key = kb[i],
      cx = cx + rc * s,
      cy = cy - rc * co,
      w = bw,
      h = len,
      fill = cols[if lv then (v * LV + 0.5) // 1 + 1 else i],
      radius = round * min(bw, len),
      rot = th,
      glow = true,
    }
    if room > 0 then
      local pv = peaks[i]
      local pl = minS + pv * (Lmax - minS)
      local col = peakCol or cols[if lv then (pv * LV + 0.5) // 1 + 1 else i]
      if dir ~= "in" then
        local rp = r0 + pl + 1 + pt / 2
        out[#out + 1] = {
          kind = "box",
          key = kp[i],
          cx = cx + rp * s,
          cy = cy - rp * co,
          w = bw,
          h = pt,
          fill = col,
          radius = pr,
          rot = th,
          glow = true,
        }
      end
      if dir ~= "out" then
        local rp = r0 - pl - 1 - pt / 2
        out[#out + 1] = {
          kind = "box",
          key = kq[i],
          cx = cx + rp * s,
          cy = cy - rp * co,
          w = bw,
          h = pt,
          fill = col,
          radius = pr,
          rot = th,
          glow = true,
        }
      end
    end
  end
end

-- Dots orbiting the inner circle, pushed outward (or inward) by their level.
function S.radial_dots(ctx)
  local c, pal, n, out = ctx.c, ctx.pal, ctx.n, ctx.out
  local values, peaks = ctx.values, ctx.peaks
  local cx, cy, R, r0, arc, start = radialFrame(ctx)
  local dir = c.radialDirection
  local slot = arc * DEG * max(r0, (R - r0) * 0.4, 1) / n
  local d = math.clamp(if c.barWidth > 0 then c.barWidth else slot - c.spacing, 1.5, max(1.5, R * 0.25))
  local pd = max(1, d * 0.45)
  local room = if c.showPeaks then pd + 1 else 0
  local edge = R - room
  r0 = min(r0, edge - d)
  local outTravel = max(0, edge - r0 - d)
  local inTravel = max(0, r0 - d - room)
  if dir ~= "out" and inTravel < 1 then
    dir = "out"
  end
  local travel = if dir == "in" then inTravel elseif dir == "both" then min(outTravel, inTravel) else outTravel
  local cols, lv = pal:colors(n)
  local peakCol = pal.peakToken ~= nil and pal:peak(1, n, 1) or nil
  local ka, kb, kp = KEYS.a, KEYS.b, KEYS.p
  local step = arc / n
  local a0 = start - arc / 2 + step / 2
  baseRing(ctx, cx, cy, r0, arc, start)
  for i = 1, n do
    local v = values[i]
    local th = a0 + (i - 1) * step
    local s, co = sin(th * DEG), cos(th * DEG)
    local col = cols[if lv then (v * LV + 0.5) // 1 + 1 else i]
    if dir ~= "in" then
      local r = r0 + d / 2 + v * travel
      out[#out + 1] = {
        kind = "box",
        key = ka[i],
        cx = cx + r * s,
        cy = cy - r * co,
        w = d,
        h = d,
        fill = col,
        radius = d / 2,
        glow = true,
      }
    end
    if dir ~= "out" then
      local r = r0 - d / 2 - v * travel
      out[#out + 1] = {
        kind = "box",
        key = kb[i],
        cx = cx + r * s,
        cy = cy - r * co,
        w = d,
        h = d,
        fill = col,
        radius = d / 2,
        glow = true,
      }
    end
    if room > 0 then
      local pv = peaks[i]
      local r = if dir == "in" then r0 - d - 1 - pd / 2 - pv * travel else r0 + d + 1 + pd / 2 + pv * travel
      out[#out + 1] = {
        kind = "box",
        key = kp[i],
        cx = cx + r * s,
        cy = cy - r * co,
        w = pd,
        h = pd,
        fill = peakCol or cols[if lv then (pv * LV + 0.5) // 1 + 1 else i],
        radius = pd / 2,
        glow = true,
      }
    end
  end
end

-- Cyclic (or clamped) Catmull-Rom resampling for smooth curves.
smooth = function(src, m: number, closed: boolean, out)
  local n = #src
  if n == 0 then
    for i = 1, m do
      out[i] = 0
    end
    return out
  end
  for i = 1, m do
    local x = if closed then (i - 1) * n / m + 1 else 1 + (i - 1) * (n - 1) / max(1, m - 1)
    local j = floor(x)
    local t = x - j
    local i0, i1, i2, i3
    if closed then
      i0, i1, i2, i3 = (j - 2) % n + 1, (j - 1) % n + 1, j % n + 1, (j + 1) % n + 1
    else
      i0, i1, i2, i3 = max(1, j - 1), min(n, j), min(n, j + 1), min(n, j + 2)
    end
    local p0, p1, p2, p3 = src[i0], src[i1], src[i2], src[i3]
    local t2 = t * t
    local v = 0.5 * ((2 * p1) + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t2 * t)
    out[i] = if v < 0 then 0 elseif v > 1 then 1 else v
  end
  for i = m + 1, #out do
    out[i] = nil
  end
  return out
end

-- A closed (or, for partial arcs, open) line around the circle, drawn as
-- rotated round-capped segments so it can carry per-segment colors.
function S.circle_wave(ctx)
  local c, pal, n, out = ctx.c, ctx.pal, ctx.n, ctx.out
  local cx, cy, R, r0, arc, start = radialFrame(ctx)
  local dir = c.radialDirection
  local lw = max(1, c.lineWidth)
  local edge = R - lw
  r0 = min(r0, edge - 1)
  local outMax, inMax = max(1, edge - r0), max(0, r0 * 0.92 - lw)
  local Lmax = if dir == "in" then inMax elseif dir == "both" then min(outMax, inMax) else outMax
  if Lmax < 1 then
    dir = "out"
    Lmax = outMax
  end
  local closed = arc >= 360
  local m = math.clamp(max(n, 96), 8, 160)
  local st = ctx.state
  st.wave = smooth(ctx.values, m, closed, st.wave or table.create(m))
  local vals = st.wave
  local minS = min(c.minSize, Lmax)
  local cols, lv = pal:colors(m)
  local xs, ys = st.xs or table.create(m), st.ys or table.create(m)
  st.xs, st.ys = xs, ys
  local step = if closed then arc / m else arc / (m - 1)
  local a0 = start - arc / 2 + (if closed then step / 2 else 0)
  baseRing(ctx, cx, cy, r0, arc, start)
  for pass = 1, 2 do
    local sign = if pass == 1 then 1 else -1
    if (sign > 0 and dir == "in") or (sign < 0 and dir == "out") then
      continue
    end
    local keys = if sign > 0 then KEYS.o else KEYS.i
    for i = 1, m do
      local th = (a0 + (i - 1) * step) * DEG
      local r = r0 + sign * (minS + vals[i] * (Lmax - minS))
      xs[i] = cx + r * sin(th)
      ys[i] = cy - r * cos(th)
    end
    local last = if closed then m else m - 1
    for i = 1, last do
      local j = if i == m then 1 else i + 1
      local dx, dy = xs[j] - xs[i], ys[j] - ys[i]
      local len = sqrt(dx * dx + dy * dy)
      local v = (vals[i] + vals[j]) / 2
      out[#out + 1] = {
        kind = "box",
        key = keys[i],
        cx = (xs[i] + xs[j]) / 2,
        cy = (ys[i] + ys[j]) / 2,
        w = len + lw * 0.9,
        h = lw,
        fill = cols[if lv then (v * LV + 0.5) // 1 + 1 else i],
        radius = lw / 2,
        rot = math.atan2(dy, dx) / DEG,
        glow = true,
      }
    end
  end
end

-- Translucent rounded petals growing from the center.
function S.bloom(ctx)
  local c, pal, n, out = ctx.c, ctx.pal, ctx.n, ctx.out
  local values = ctx.values
  local cx, cy, R, _, arc, start = radialFrame(ctx)
  local r0 = R * 0.06
  local pw = math.clamp(arc * DEG * (r0 + R * 0.4) / n * 1.35, 2, R * 0.5)
  if c.barWidth > 0 then
    pw = min(c.barWidth, R * 0.5)
  end
  local edge = sqrt(max(1, R * R - (pw / 2) ^ 2))
  local Lmax = max(pw, edge - r0)
  local minS = min(max(pw, c.minSize), Lmax)
  local cols, lv = pal:colors(n, 0.72)
  local kp = KEYS.p
  local step = arc / n
  local a0 = start - arc / 2 + step / 2
  for i = 1, n do
    local v = values[i]
    local th = a0 + (i - 1) * step
    local L = minS + v * (Lmax - minS)
    local rc = r0 + L / 2
    out[#out + 1] = {
      kind = "box",
      key = kp[i],
      cx = cx + rc * sin(th * DEG),
      cy = cy - rc * cos(th * DEG),
      w = pw,
      h = L,
      fill = cols[if lv then (v * LV + 0.5) // 1 + 1 else i],
      radius = pw / 2,
      rot = th,
      glow = true,
    }
  end
  local core = r0 * 2.6
  out[#out + 1] = {
    kind = "box",
    key = "core",
    cx = cx,
    cy = cy,
    w = core,
    h = core,
    fill = pal:secondary(),
    radius = core / 2,
    glow = true,
  }
end

-- Bars along an Archimedean spiral, widening as they wind outward.
function S.spiral(ctx)
  local c, pal, n, out = ctx.c, ctx.pal, ctx.n, ctx.out
  local values, peaks = ctx.values, ctx.peaks
  local cx, cy, R, r0, _, start = radialFrame(ctx)
  local turns = max(0.25, c.spiralTurns)
  local room = peakRoom(c)
  local Lmax = max(2, (R - r0) / (turns + 1))
  local bwMax = Lmax * 0.8
  local edge = sqrt(max(1, R * R - (bwMax / 2) ^ 2)) - room
  local reach = max(0, edge - r0 - Lmax)
  local minS = min(c.minSize, Lmax)
  local pt = c.peakThickness
  local round = c.roundness * 0.5
  local cols, lv = pal:colors(n)
  local peakCol = pal.peakToken ~= nil and pal:peak(1, n, 1) or nil
  local kb, kp = KEYS.b, KEYS.p
  local fixedW = c.barWidth
  local spacing = c.spacing
  local perBar = turns * 2 * math.pi / n
  for i = 1, n do
    local v = values[i]
    local f = (i - 0.5) / n
    local th = start + f * turns * 360
    local s, co = sin(th * DEG), cos(th * DEG)
    local r = r0 + f * reach
    local bw = if fixedW > 0 then min(fixedW, bwMax) else math.clamp(perBar * max(r, 2) - spacing, 1, bwMax)
    local L = minS + v * (Lmax - minS)
    local rc = r + L / 2
    out[#out + 1] = {
      kind = "box",
      key = kb[i],
      cx = cx + rc * s,
      cy = cy - rc * co,
      w = bw,
      h = L,
      fill = cols[if lv then (v * LV + 0.5) // 1 + 1 else i],
      radius = round * min(bw, L),
      rot = th,
      glow = true,
    }
    if room > 0 then
      local pv = peaks[i]
      local rp = r + minS + pv * (Lmax - minS) + 1 + pt / 2
      out[#out + 1] = {
        kind = "box",
        key = kp[i],
        cx = cx + rp * s,
        cy = cy - rp * co,
        w = bw,
        h = pt,
        fill = peakCol or cols[if lv then (pv * LV + 0.5) // 1 + 1 else i],
        radius = 0,
        rot = th,
        glow = true,
      }
    end
  end
end

-- Concentric arc gauges, bass on the outside.
function S.rings(ctx)
  local c, pal, out = ctx.c, ctx.pal, ctx.out
  local cx, cy, R, r0, arc = radialFrame(ctx)
  local g = max(1, c.ringCount)
  local vals = Dsp.groups(ctx.spectrum, g)
  local gap = max(0, c.spacing)
  local inner = min(r0, R - g * 1.5)
  local th = max(1, (R - inner - (g - 1) * gap) / g)
  local maxProg = arc / 360
  local full = arc >= 360
  local minP = if c.minSize > 0 then 0.01 else 0
  local cols, lv = pal:colors(g)
  local tracks = if pal.trackAlpha > 0 then pal:colors(g, pal.trackAlpha) else nil
  local kr, kt = KEYS.r, KEYS.t
  for j = 1, g do
    local v = vals[j]
    local outerR = R - (j - 1) * (th + gap)
    if outerR - th < 0.5 then
      break
    end
    local d = 2 * outerR
    local dirSign = if j % 2 == 0 then -1 else 1
    local rot = (if full then 0 else -arc / 2) + c.radialRotation + ctx.t * c.spin * dirSign
    local track = CLEAR
    if tracks ~= nil then
      local tc = tracks[if lv then 1 else j]
      if full then
        track = tc
      else
        -- A ring's track spans the whole circle; for a partial arc draw the
        -- track as its own arc behind the gauge instead.
        out[#out + 1] = {
          kind = "ring",
          key = kt[j],
          cx = cx,
          cy = cy,
          w = d,
          h = d,
          rot = rot,
          progress = maxProg,
          fill = tc,
          track = CLEAR,
          thickness = th,
        }
      end
    end
    out[#out + 1] = {
      kind = "ring",
      key = kr[j],
      cx = cx,
      cy = cy,
      w = d,
      h = d,
      rot = rot,
      progress = (minP + v * (1 - minP)) * maxProg,
      fill = cols[if lv then (v * LV + 0.5) // 1 + 1 else j],
      track = track,
      thickness = th,
    }
  end
end

-- A breathing orb: the core follows the bass, rings follow mids and highs.
-- Layout sizes are fixed and the paint-only `scale` animates them, so the
-- layout never reflows while the orb pulses.
function S.pulse(ctx)
  local pal, out = ctx.pal, ctx.out
  local W, H = ctx.W, ctx.H
  local sp = ctx.spectrum
  local bass = Dsp.band(sp, 0, 0.18)
  local mid = Dsp.band(sp, 0.18, 0.6)
  local high = Dsp.band(sp, 0.6, 1)
  local level = (bass + mid + high) / 3
  local cx, cy = W / 2, H / 2
  local D = max(4, min(W, H) - 2 - ctx.c.glow)
  local halo = D * 0.8
  out[#out + 1] = {
    kind = "box",
    key = "halo",
    cx = cx,
    cy = cy,
    w = halo,
    h = halo,
    fill = pal:at(1, 3, level, 0.22),
    radius = halo / 2,
    soft = max(6, D * 0.12),
    op = math.clamp(0.25 + level * 1.4, 0, 1),
    scale = 0.8 + 0.25 * level,
  }
  out[#out + 1] = {
    kind = "ring",
    key = "high",
    cx = cx,
    cy = cy,
    w = D,
    h = D,
    progress = 1,
    fill = pal:at(3, 3, high, 0.55),
    track = CLEAR,
    thickness = max(1, D * 0.012),
    scale = 0.62 + 0.38 * high,
  }
  out[#out + 1] = {
    kind = "ring",
    key = "mid",
    cx = cx,
    cy = cy,
    w = D,
    h = D,
    progress = 1,
    fill = pal:at(2, 3, mid, 0.85),
    track = CLEAR,
    thickness = max(1.5, D * 0.02),
    scale = 0.5 + 0.35 * mid,
  }
  local coreD = D * 0.5
  out[#out + 1] = {
    kind = "box",
    key = "core",
    cx = cx,
    cy = cy,
    w = coreD,
    h = coreD,
    fill = pal:at(1, 3, bass),
    radius = coreD / 2,
    scale = 0.45 + 0.55 * bass,
    glow = true,
  }
end

return S
