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

local function nodeFor(p, key, w, h, tx, ty, rot, scale, glowSoft, glowOp)
  local kind = p.kind
  if kind == "box" then
    return {
      type = "box",
      props = {
        key = key,
        width = w,
        height = h,
        fill = p.fill or CLEAR,
        radius = (p.radius or 0) + (if glowSoft then glowSoft * 0.5 else 0),
        softness = glowSoft or p.soft or 1,
        opacity = glowOp or p.op or 1,
        translateX = tx,
        translateY = ty,
        rotation = rot,
        scale = scale,
      },
      children = NO_CHILDREN,
    }
  elseif kind == "ring" then
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
        opacity = p.op or 1,
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
        opacity = p.op or 1,
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
        opacity = p.op or 1,
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
-- box flagged `glow`.
function M.compose(W: number, H: number, prims, opts)
  local vertical = opts.vertical == true
  local frameH = opts.frameH or H
  -- Primitives are in viewport coordinates; the viewport may extend past the
  -- W x H root on any side (it is centered on it).
  local ox, oy = opts.offsetX or 0, opts.offsetY or 0
  local glow = opts.glow or 0
  local glowAlpha = opts.glowStrength or 0.6
  local big = math.max(W, H) * 2
  local count = #prims
  local slots = table.create(if glow > 0 then count * 2 else count)
  local ns = 0
  -- Pass 1 draws glow copies (behind everything), pass 2 the primitives.
  for pass = (if glow > 0 then 1 else 2), 2 do
    for i = 1, count do
      local p = prims[i]
      local isGlow = pass == 1
      if isGlow and not (p.glow and p.kind == "box") then
        continue
      end
      local cx, cy, w, h, rot = p.cx, p.cy, p.w, p.h, p.rot or 0
      if vertical then
        cx, cy = frameH - p.cy, p.cx
        if p.kind == "box" then
          w, h = h, w
        else
          rot += 90
        end
      end
      if w < EPS or h < EPS then
        continue
      end
      local key = if isGlow then glowKeys[p.key] else p.key
      local scale = p.scale
      if scale == nil or scale <= 0.001 then
        scale = 1
      end
      local node = nodeFor(
        p,
        key,
        w,
        h,
        cx - w / 2 - ox,
        cy - h / 2 - oy,
        rot,
        scale,
        if isGlow then glow else nil,
        if isGlow then glowAlpha * (p.op or 1) else nil
      )
      local child = node
      if w > W + 0.5 then
        child = {
          type = "row",
          props = { key = wideKeys[key], width = EPS, height = big, align = "start" },
          children = { node },
        }
      end
      ns += 1
      slots[ns] = {
        type = "column",
        props = { key = slotKeys[key], width = W, height = EPS, align = "start" },
        children = { child },
      }
    end
  end

  -- Containers hold at most MAX_CHILDREN children (the host drops the rest),
  -- so larger scenes nest their slots in zero-height groups.
  local children = slots
  if ns > MAX_CHILDREN then
    children = {}
    for g = 0, (ns - 1) // MAX_CHILDREN do
      local group = table.move(slots, g * MAX_CHILDREN + 1, math.min(ns, (g + 1) * MAX_CHILDREN), 1, {})
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
      key = "canvas",
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
