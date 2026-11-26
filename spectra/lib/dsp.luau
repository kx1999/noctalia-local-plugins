--!nonstrict
-- Spectrum processing shared by every entry.
--
-- Pipeline per frame:
--   raw source bands (0..1, low -> high frequency)
--   -> tilt / gain / noise gate / curve        (per source band)
--   -> resample to the analysis resolution     (`spectrum`, still low -> high)
--   -> neighbour spread, attack/release smoothing, gravity peaks
--   -> layout (reverse / mirror) into `values` and `peaks` for drawing.
--
-- Time-based smoothing uses real frame deltas, so behaviour does not change
-- with the source frame rate (the PipeWire feed can run at 240 Hz, cava at 60).

local M = {}
M.__index = M

local MIRROR_LAYOUTS = { mirror_center = true, mirror_edges = true }

function M.isMirror(layout: string): boolean
  return MIRROR_LAYOUTS[layout] == true
end

-- Number of analysis bands needed to draw `displayCount` elements in `layout`.
function M.analysisCount(displayCount: number, layout: string): number
  if M.isMirror(layout) then
    return math.max(1, math.ceil(displayCount / 2))
  end
  return math.max(1, displayCount)
end

-- Resample `src` (length m) to length n. Downsampling takes the max of each
-- covered range (keeps transients); upsampling interpolates linearly.
function M.resample(src, n: number, out)
  out = out or table.create(n, 0)
  local m = #src
  if m == 0 then
    for i = 1, n do
      out[i] = 0
    end
    return out
  end
  if m == n then
    for i = 1, n do
      out[i] = src[i]
    end
    return out
  end
  if m > n then
    for i = 1, n do
      local a = math.floor((i - 1) * m / n) + 1
      local b = math.max(a, math.floor(i * m / n))
      local mx = 0
      for j = a, b do
        local v = src[j]
        if v > mx then
          mx = v
        end
      end
      out[i] = mx
    end
  else
    for i = 1, n do
      local x = (i - 0.5) * m / n + 0.5
      local lo = math.clamp(math.floor(x), 1, m)
      local hi = math.min(lo + 1, m)
      local t = math.clamp(x - lo, 0, 1)
      out[i] = src[lo] + (src[hi] - src[lo]) * t
    end
  end
  for i = n + 1, #out do
    out[i] = nil
  end
  return out
end

-- Averages of `k` contiguous groups of `src` (used by meters / rings / pulse).
function M.groups(src, k: number)
  local out = table.create(k, 0)
  local m = #src
  if m == 0 then
    return out
  end
  for g = 1, k do
    local a = math.floor((g - 1) * m / k) + 1
    local b = math.max(a, math.floor(g * m / k))
    local sum = 0
    for j = a, b do
      sum += src[j]
    end
    out[g] = sum / (b - a + 1)
  end
  return out
end

-- Average of the [fromFrac, toFrac) slice of `src`.
function M.band(src, fromFrac: number, toFrac: number): number
  local m = #src
  if m == 0 then
    return 0
  end
  local a = math.clamp(math.floor(fromFrac * m) + 1, 1, m)
  local b = math.clamp(math.ceil(toFrac * m), a, m)
  local sum = 0
  for j = a, b do
    sum += src[j]
  end
  return sum / (b - a + 1)
end

function M.new()
  local self = setmetatable({}, M)
  self.n = 0 -- display element count
  self.na = 0 -- analysis band count
  self.layout = "low_high"
  self.shaped = {}
  self.target = {}
  self.spectrum = {}
  self.peakLevel = {}
  self.peakHold = {}
  self.peakVel = {}
  self.values = {}
  self.peaks = {}
  self.silentMs = 0
  self.idle = false
  self.energy = 0
  self:configure({})
  return self
end

function M:configure(o)
  self.gain = o.gain or 1
  self.floor = math.clamp(o.floor or 0, 0, 0.95)
  self.curve = math.max(0.05, o.curve or 1)
  self.tilt = o.tilt or 0
  self.spread = math.clamp(o.spread or 0, 0, 0.98)
  self.attackMs = math.max(0, o.attackMs or 0)
  self.releaseMs = math.max(0, o.releaseMs or 0)
  self.holdMs = math.max(0, o.peakHoldMs or 400)
  self.gravity = math.max(0.01, o.peakGravity or 2.5)
  self.idleDelayMs = math.max(0, o.idleDelayMs or 1500)
  self.minLevel = math.clamp(o.minLevel or 0, 0, 1)
  local n = math.max(1, math.floor(o.count or self.n or 1))
  local layout = o.layout or self.layout
  if n ~= self.n or layout ~= self.layout then
    self.n = n
    self.layout = layout
    self.na = M.analysisCount(n, layout)
    for _, t in ipairs({ self.target, self.spectrum, self.peakLevel, self.peakHold, self.peakVel }) do
      table.clear(t)
      for i = 1, self.na do
        t[i] = 0
      end
    end
    table.clear(self.values)
    table.clear(self.peaks)
    for i = 1, n do
      self.values[i] = 0
      self.peaks[i] = 0
    end
  end
end

-- Track silence on the real source (nil = no signal). Drives `idle`, which
-- stays meaningful while synthetic frames (demo / breathing) are drawn.
function M:observe(raw, dtMs: number)
  local energy = 0
  if raw ~= nil then
    local m = #raw
    for i = 1, m do
      energy += raw[i] or 0
    end
    energy = if m > 0 then energy / m else 0
  end
  self.energy = energy
  if energy < 0.003 then
    self.silentMs += math.max(0, dtMs)
  else
    self.silentMs = 0
  end
  self.idle = self.silentMs >= self.idleDelayMs
end

-- Advance one frame. `raw` is the spectrum to draw (array 0..1, low -> high)
-- or nil for silence. `dtMs` is the time since the previous step.
function M:step(raw, dtMs: number)
  dtMs = math.clamp(dtMs or 16, 0, 250)
  local shaped = self.shaped
  table.clear(shaped)
  if raw ~= nil then
    local m = #raw
    local gain, floor, curve, tilt = self.gain, self.floor, self.curve, self.tilt
    local invFloor = 1 / (1 - floor)
    for i = 1, m do
      local r = raw[i] or 0
      local f = if m > 1 then (i - 1) / (m - 1) else 0.5
      local w = 1 + tilt * (f * 2 - 1)
      local v = r * gain * (if w > 0 then w else 0)
      v = (v - floor) * invFloor
      if v <= 0 then
        v = 0
      else
        if v > 1 then
          v = 1
        end
        if curve ~= 1 then
          v = v ^ curve
        end
      end
      shaped[i] = v
    end
  end

  local na = self.na
  local target = M.resample(shaped, na, self.target)

  -- Neighbour spread (a cheap monstercat-style filter): each band is lifted to
  -- a decaying fraction of its neighbours.
  local spread = self.spread
  if spread > 0 and na > 1 then
    for i = 2, na do
      local v = target[i - 1] * spread
      if v > target[i] then
        target[i] = v
      end
    end
    for i = na - 1, 1, -1 do
      local v = target[i + 1] * spread
      if v > target[i] then
        target[i] = v
      end
    end
  end

  local aUp = if self.attackMs <= 0 then 1 else 1 - math.exp(-dtMs / self.attackMs)
  local aDown = if self.releaseMs <= 0 then 1 else 1 - math.exp(-dtMs / self.releaseMs)
  local spectrum, pk, hold, vel = self.spectrum, self.peakLevel, self.peakHold, self.peakVel
  local dt = dtMs / 1000
  local g = self.gravity
  for i = 1, na do
    local cur = spectrum[i]
    local t = target[i]
    cur += (t - cur) * (if t > cur then aUp else aDown)
    if cur < 0.0005 then
      cur = 0
    end
    spectrum[i] = cur

    if cur >= pk[i] then
      pk[i] = cur
      hold[i] = self.holdMs
      vel[i] = 0
    elseif hold[i] > 0 then
      hold[i] -= dtMs
    else
      vel[i] += g * dt
      local p = pk[i] - vel[i] * dt
      pk[i] = if p > cur then p else cur
    end
  end

  self:arrange()
end

-- Map the analysis spectrum onto display order.
function M:arrange()
  local n, na, layout = self.n, self.na, self.layout
  local spectrum, pk, values, peaks = self.spectrum, self.peakLevel, self.values, self.peaks
  if layout == "high_low" then
    for i = 1, n do
      local j = na - i + 1
      values[i] = spectrum[j]
      peaks[i] = pk[j]
    end
  elseif layout == "mirror_center" then
    -- Bass in the middle, treble at both edges.
    local odd = n % 2 == 1
    local mid = math.ceil(n / 2)
    for i = 1, n do
      local j
      if i <= mid then
        j = mid - i + 1
      else
        j = i - mid + (if odd then 1 else 0)
      end
      j = math.clamp(j, 1, na)
      values[i] = spectrum[j]
      peaks[i] = pk[j]
    end
  elseif layout == "mirror_edges" then
    -- Bass at both edges, treble in the middle.
    for i = 1, n do
      local j = math.clamp(math.min(i, n - i + 1), 1, na)
      values[i] = spectrum[j]
      peaks[i] = pk[j]
    end
  else
    for i = 1, n do
      values[i] = spectrum[i]
      peaks[i] = pk[i]
    end
  end
end

-- True once every element and peak has fallen to zero (nothing left to animate).
function M:settled(): boolean
  for i = 1, self.na do
    if self.spectrum[i] > 0.001 or self.peakLevel[i] > 0.001 then
      return false
    end
  end
  return true
end

-- ── Synthetic signals ────────────────────────────────────────────────────────

-- A music-like test signal: a kick at 120 BPM, a moving mid-range melody and
-- shimmering highs. Used by the `demo` IPC command and the editor preview.
function M.demo(m: number, tSec: number, out)
  out = out or table.create(m, 0)
  local beat = (tSec * 2) % 1
  local kick = math.exp(-beat * 7)
  local snare = math.exp(-((tSec * 2 + 0.5) % 1) * 9) * (if math.floor(tSec * 2) % 2 == 0 then 1 else 0.4)
  local melody = 0.35 + 0.3 * math.sin(tSec * 0.9)
  for i = 1, m do
    local f = if m > 1 then (i - 1) / (m - 1) else 0
    local wob = 0.5 + 0.5 * math.sin(tSec * (2.1 + f * 3.7) + i * 1.7)
    local wob2 = 0.5 + 0.5 * math.sin(tSec * (5.3 - f * 2.2) + i * 0.61)
    local bass = kick * math.exp(-f * 9) * 0.95
    local mid = math.exp(-((f - melody) ^ 2) * 40) * (0.45 + 0.35 * wob)
    local hats = snare * f * 0.55 * wob2
    local floor = 0.08 * (1 - f) * wob
    out[i] = math.clamp(bass + mid + hats + floor, 0, 1)
  end
  return out
end

-- A slow, low "breathing" wave for the idle state.
function M.breathe(m: number, tSec: number, out)
  out = out or table.create(m, 0)
  for i = 1, m do
    out[i] = 0.05 + 0.06 * (0.5 + 0.5 * math.sin(tSec * 1.6 - i * 0.45))
  end
  return out
end

return M
