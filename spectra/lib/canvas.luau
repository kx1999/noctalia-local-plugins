--!nonstrict
-- Absolute placement on top of Noctalia's flex layout.
--
-- ui.* has no canvas and no x/y props, but every node accepts paint-only
-- translateX/translateY/rotation/scale (plugin API 52). Each primitive is
-- wrapped in a "slot": a column with a near-zero explicit height, so every
-- slot sits at the canvas origin and the primitive's translate is its
-- absolute position. Flex never constrains a child along its main axis, so a
-- primitive may be taller than its slot; one wider than the canvas gets an
-- extra row level (whose main axis is horizontal) for the same reason.
--
-- Shapes describe primitives in a horizontal frame (bands left -> right,
-- amplitude up). For vertical bars the frame is rotated 90° clockwise, so
-- "bottom" baselines sit on the left.
--
-- Performance note: Noctalia meters every Luau call and loop iteration
-- against the callback CPU budget, so this file builds node tables directly
-- (the same {type, props, children} shape ui.* produces) in a single loop.

local M = {}

local EPS = 0.0001
local CLEAR = "#00000000"
local NO_CHILDREN = table.freeze({})

local slotKeys = setmetatable({}, {
  __index = function(t, k)
    local v = "s" .. k
    t[k] = v
    return v
  end,
})
local wideKeys = setmetatable({}, {
  __index = function(t, k)
    local v = "w" .. k
    t[k] = v
    return v
  end,
})
local glowKeys = setmetatable({}, {
  __index = function(t, k)
    local v = k .. "~"
    t[k] = v
    return v
  end,
})
local groupKeys = setmetatable({}, {
  __index = function(t, k)
    local v = "grp" .. k
    t[k] = v
    return v
  end,
})

-- Noctalia drops children beyond this count in any one container.
local MAX_CHILDREN = 250
M.MAX_CHILDREN = MAX_CHILDREN

-- Primitive kinds (every kind takes `rot` in degrees and a paint-only `scale`):
--   box   { cx, cy, w, h, fill, radius?, soft?, op?, glow? }
--   ring  { cx, cy, w, h, progress, fill, track, thickness, op? }
--   graph { cx, cy, w, h, values, values2?, color, color2?, lineWidth, fillOpacity }
--   label { cx, cy, w, h, text, fontSize, color, fontFamily?, maxLines? }
--   node  { cx, cy, w, h, node }  -- a prebuilt ui node laid out at w x h

-- Placement props. translate is absolute (every node sits at the canvas
-- origin, see below). rotation / opacity / scale are stateful on the host (a
-- reused node keeps the last value it was given), so they are sent whenever
-- a primitive's call site uses them at all, never omitted frame by frame.
-- Style props the host resets when omitted (fill, radius, softness) are
-- dropped at their defaults.
local function nodeFor(p, key, w, h, tx, ty, rot, scale, glowSoft, glowOp)
  local kind = p.kind
  if kind == "ring" then
    local prog = p.progress or 0
    return {
      type = "ring",
      props = {
        key = key,
        width = w,
        height = h,
        progress = if prog < 0 then 0 elseif prog > 1 then 1 else prog,
        fill = p.fill,
        track = p.track or CLEAR,
        thickness = p.thickness or 2,
        opacity = p.op,
        translateX = tx,
        translateY = ty,
        rotation = rot,
        scale = scale,
      },
      children = NO_CHILDREN,
    }
  elseif kind == "graph" then
    return {
      type = "graph",
      props = {
        key = key,
        width = w,
        height = h,
        values = p.values,
        values2 = p.values2,
        color = p.color,
        color2 = p.color2,
        lineWidth = p.lineWidth,
        fillOpacity = p.fillOpacity,
        opacity = p.op,
        translateX = tx,
        translateY = ty,
        rotation = rot,
        scale = scale,
      },
      children = NO_CHILDREN,
    }
  elseif kind == "label" then
    return {
      type = "label",
      props = {
        key = key,
        width = w,
        height = h,
        text = p.text,
        fontSize = p.fontSize,
        color = p.color,
        fontFamily = p.fontFamily,
        maxLines = p.maxLines,
        textAlign = "center",
        baseline = "textFixedHeight",
        opacity = p.op,
        translateX = tx,
        translateY = ty,
        rotation = rot,
        scale = scale,
      },
      children = NO_CHILDREN,
    }
  end
  local node = p.node
  local props = node.props
  props.key = key
  props.width = w
  props.height = h
  props.translateX = tx
  props.translateY = ty
  props.rotation = rot
  props.scale = scale
  return node
end

-- Build the ui tree for `prims` on a canvas of W x H (the canvas as drawn).
-- opts.vertical rotates the horizontal shape frame onto the canvas (its
-- height is opts.frameH); opts.glow > 0 adds a feathered copy behind every
-- box flagged `glow`; opts.key names the root (change it whenever the
-- primitives' prop sets change, e.g. with the shape, so nothing stale is
-- reused).
--
-- Every node is laid out at the canvas origin and placed by translate. A run
-- of consecutive nodes with the same width shares one row whose gap is minus
-- that width: flex advances by width + gap = 0, so each child starts at the
-- origin with no slot of its own (same-height runs share a column the same
-- way). That halves the nodes the host marshals, reconciles and lays out.
-- Other nodes get a zero-height slot each.
function M.compose(W: number, H: number, prims, opts)
  local vertical = opts.vertical == true
  local frameH = opts.frameH or H
  -- Primitives are in viewport coordinates; the viewport may extend past the
  -- W x H root on any side (it is centered on it).
  local ox, oy = opts.offsetX or 0, opts.offsetY or 0
  local glow = opts.glow or 0
  local glowAlpha = opts.glowStrength or 0.6
  local big = 2 * math.max(W, H) + 4 * math.max(math.abs(ox), math.abs(oy))
  local count = #prims
  local slots = {}
  local nslots = 0
  -- The open run: nodes run[1..rn] (rn >= 1) of equal width runW (mode
  -- "w"), equal height runH ("h"), or one node so far (mode nil).
  local run = table.create(16)
  local rn = 0
  local runW, runH, runMode = 0, 0, nil

  local function close()
    if rn == 0 then
      return
    end
    local child
    if runMode == "w" then
      child = {
        type = "row",
        props = { height = big, gap = -runW, align = "start" },
        children = table.move(run, 1, rn, 1, table.create(rn)),
      }
    elseif runMode == "h" then
      child = {
        type = "row",
        props = { width = EPS, height = big, align = "start" },
        children = {
          {
            type = "column",
            props = { gap = -runH, align = "start" },
            children = table.move(run, 1, rn, 1, table.create(rn)),
          },
        },
      }
    else
      child = run[1]
      if runW > W + 0.5 then
        -- Wider than the slot: a row lets it overflow along its main axis.
        child = {
          type = "row",
          props = { width = EPS, height = big, align = "start" },
          children = { child },
        }
      end
    end
    nslots += 1
    slots[nslots] = {
      type = "column",
      -- Positional keys: a run boundary that shifts keeps the other slots.
      props = { key = slotKeys[nslots], width = W, height = EPS, align = "start" },
      children = { child },
    }
    rn = 0
    runMode = nil
  end

  -- Pass 1 draws glow copies (behind everything), pass 2 the primitives.
  for pass = (if glow > 0 then 1 else 2), 2 do
    local isGlow = pass == 1
    for i = 1, count do
      local p = prims[i]
      local isBox = p.kind == "box"
      if isGlow and not (p.glow and isBox) then
        continue
      end
      local cx, cy, w, h, rot = p.cx, p.cy, p.w, p.h, p.rot
      if vertical then
        cx, cy = frameH - p.cy, p.cx
        if isBox then
          w, h = h, w
        else
          rot = (rot or 0) + 90
        end
      end
      if w < EPS or h < EPS then
        continue
      end
      local key = if isGlow then glowKeys[p.key] else p.key
      local scale = p.scale
      if scale ~= nil and scale <= 0.001 then
        scale = 1
      end
      local tx, ty = cx - w / 2 - ox, cy - h / 2 - oy
      local node
      if isBox then
        local radius = p.radius
        local soft = p.soft
        local op = p.op
        if isGlow then
          radius = (radius or 0) + glow * 0.5
          soft = glow
          op = glowAlpha * (op or 1)
        end
        local fill = p.fill
        node = {
          type = "box",
          props = {
            key = key,
            width = w,
            height = h,
            fill = if fill ~= CLEAR then fill else nil,
            radius = if radius ~= nil and radius > 0 then radius else nil,
            softness = if soft ~= nil and soft ~= 1 then soft else nil,
            opacity = op,
            translateX = tx,
            translateY = ty,
            rotation = rot,
            scale = scale,
          },
          children = NO_CHILDREN,
        }
      else
        node = nodeFor(p, key, w, h, tx, ty, rot, scale)
      end
      -- Extend the open run, or close it and start a new one.
      if rn > 0 and rn < MAX_CHILDREN and (
          (runMode ~= "h" and w == runW) or (runMode ~= "w" and h == runH)
        ) then
        if runMode == nil then
          runMode = if w == runW then "w" else "h"
        end
        rn += 1
        run[rn] = node
      else
        close()
        rn = 1
        run[1] = node
        runW, runH = w, h
      end
    end
  end
  close()

  -- Containers hold at most MAX_CHILDREN children (the host drops the rest),
  -- so larger scenes nest their slots in zero-height groups.
  local children = slots
  if nslots > MAX_CHILDREN then
    children = {}
    for g = 0, (nslots - 1) // MAX_CHILDREN do
      local group = table.move(slots, g * MAX_CHILDREN + 1, math.min(nslots, (g + 1) * MAX_CHILDREN), 1, {})
      children[g + 1] = {
        type = "column",
        props = { key = groupKeys[g], width = W, height = EPS, align = "start" },
        children = group,
      }
    end
  end

  return {
    type = "column",
    props = {
      key = opts.key or "canvas",
      width = W,
      height = H,
      align = "start",
      justify = "start",
      gap = 0,
      opacity = opts.opacity or 1,
    },
    children = children,
  }
end

-- A centered message (e.g. "cava not found") on an otherwise empty canvas.
function M.message(W: number, H: number, text: string, color: string?)
  return ui.column({ key = "canvas-msg", width = W, height = H, align = "center", justify = "center" }, {
    ui.label({
      key = "msg",
      text = text,
      color = color or "on_surface_variant",
      fontSize = math.clamp(H * 0.18, 9, 22),
      maxWidth = W,
      maxLines = 3,
      textAlign = "center",
    }),
  })
end

M.CLEAR = CLEAR
M.NO_CHILDREN = NO_CHILDREN

return M
