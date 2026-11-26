--!nonstrict
-- Color helpers shared by the bar and desktop entries.
--
-- Colors come from settings as a palette role ("primary"), a role with alpha
-- ("primary/0.5") or a hex value ("#rrggbb" / "#rrggbbaa"). Solid colors are
-- handed to the UI as role tokens so the shell resolves them live against the
-- active palette; gradients, rainbow and by-level coloring need real RGB, so
-- roles are resolved through noctalia.getColor() and re-resolved every second
-- (see Palette:refresh) to follow wallpaper/theme changes.

local M = {}

-- Steps used for "by level" colors. At 240 steps neighbouring levels differ
-- by well under one 8-bit step for any pair of theme colors, so level
-- gradients do not band (240 is also a multiple of the spectrogram's 24).
M.LEVELS = 240

local function clamp01(x: number): number
  if x < 0 then
    return 0
  elseif x > 1 then
    return 1
  end
  return x
end

local function byte(x: number): number
  return math.clamp(math.floor(x * 255 + 0.5), 0, 255)
end

-- "#rgb" | "#rrggbb" | "#rrggbbaa" -> { r, g, b, a } in 0..1, or nil.
function M.parseHex(s)
  if type(s) ~= "string" then
    return nil
  end
  local h = s:match("^#(%x+)$")
  if h == nil then
    return nil
  end
  if #h == 3 then
    h = h:sub(1, 1):rep(2) .. h:sub(2, 2):rep(2) .. h:sub(3, 3):rep(2)
  end
  if #h ~= 6 and #h ~= 8 then
    return nil
  end
  local r = tonumber(h:sub(1, 2), 16) / 255
  local g = tonumber(h:sub(3, 4), 16) / 255
  local b = tonumber(h:sub(5, 6), 16) / 255
  local a = if #h == 8 then tonumber(h:sub(7, 8), 16) / 255 else 1
  return { r, g, b, a }
end

function M.isRole(token): boolean
  return type(token) == "string" and token ~= "" and token:sub(1, 1) ~= "#"
end

-- Resolve any token to RGBA. Unknown roles fall back to `fallback`, then white.
function M.resolve(token, fallback)
  if token == nil or token == "" then
    token = fallback or "primary"
  end
  local c = M.parseHex(token)
  if c ~= nil then
    return c
  end
  local role, alpha = token:match("^([%w_]+)/([%d%.]+)$")
  role = role or token
  c = M.parseHex(noctalia.getColor(role))
  if c == nil and fallback ~= nil and fallback ~= token then
    c = M.parseHex(noctalia.getColor(fallback))
  end
  c = c or { 1, 1, 1, 1 }
  return { c[1], c[2], c[3], c[4] * (tonumber(alpha) or 1) }
end

function M.toHex(c, alphaMul: number?): string
  local a = clamp01((c[4] or 1) * (alphaMul or 1))
  return string.format("#%02x%02x%02x%02x", byte(c[1]), byte(c[2]), byte(c[3]), byte(a))
end

-- A UI color token for `token` at extra alpha `alpha`. Roles stay live tokens
-- ("primary/0.4"); hex values are folded into "#rrggbbaa".
function M.token(token, alpha: number?): string
  alpha = alpha or 1
  if M.isRole(token) and not token:find("/", 1, true) then
    if alpha >= 0.999 then
      return token
    end
    return string.format("%s/%.3f", token, clamp01(alpha))
  end
  return M.toHex(M.resolve(token), alpha)
end

function M.mix(a, b, t: number)
  return {
    a[1] + (b[1] - a[1]) * t,
    a[2] + (b[2] - a[2]) * t,
    a[3] + (b[3] - a[3]) * t,
    (a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * t,
  }
end

-- Piecewise-linear gradient over an array of RGBA stops.
function M.gradient(stops, t: number)
  local n = #stops
  if n == 1 then
    return stops[1]
  end
  t = clamp01(t) * (n - 1)
  local i = math.floor(t)
  if i >= n - 1 then
    i = n - 2
  end
  return M.mix(stops[i + 1], stops[i + 2], t - i)
end

function M.toHsl(c)
  local r, g, b = c[1], c[2], c[3]
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local l = (mx + mn) / 2
  if mx == mn then
    return 0, 0, l
  end
  local d = mx - mn
  local s = if l > 0.5 then d / (2 - mx - mn) else d / (mx + mn)
  local h
  if mx == r then
    h = (g - b) / d + (if g < b then 6 else 0)
  elseif mx == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  return h * 60, s, l
end

local function hue2rgb(p, q, t)
  if t < 0 then
    t += 1
  end
  if t > 1 then
    t -= 1
  end
  if t < 1 / 6 then
    return p + (q - p) * 6 * t
  end
  if t < 1 / 2 then
    return q
  end
  if t < 2 / 3 then
    return p + (q - p) * (2 / 3 - t) * 6
  end
  return p
end

function M.fromHsl(h: number, s: number, l: number, a: number?)
  h = (h % 360) / 360
  if s <= 0 then
    return { l, l, l, a or 1 }
  end
  local q = if l < 0.5 then l * (1 + s) else l + s - l * s
  local p = 2 * l - q
  return { hue2rgb(p, q, h + 1 / 3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1 / 3), a or 1 }
end

-- ── Palette ──────────────────────────────────────────────────────────────────
-- Turns the color settings into per-element colors. `at(i, n, level)` is the
-- color of element i of n whose current level is `level` (0..1).

local Palette = {}
Palette.__index = Palette

function M.newPalette(opts)
  local self = setmetatable({}, Palette)
  self.mode = opts.mode or "gradient"
  self.tokens = {}
  for _, t in ipairs({ opts.color1, opts.color2, opts.color3 }) do
    if type(t) == "string" and t ~= "" then
      table.insert(self.tokens, t)
    end
  end
  if #self.tokens == 0 then
    self.tokens = { "primary" }
  end
  self.peakToken = if type(opts.peak) == "string" and opts.peak ~= "" then opts.peak else nil
  self.alpha = opts.alpha or 1
  self.trackAlpha = opts.trackAlpha or 0
  self.rainbowSpeed = opts.rainbowSpeed or 0
  self.time = 0
  self:refresh()
  return self
end

-- Re-resolve roles to RGB (call periodically to follow theme changes).
-- Caches survive when nothing changed. Returns true when the colors changed.
function Palette:refresh(): boolean
  local stops = {}
  local sig = {}
  for _, t in ipairs(self.tokens) do
    local c = M.resolve(t)
    table.insert(stops, c)
    table.insert(sig, M.toHex(c))
  end
  local signature = table.concat(sig, ",")
  if signature == self.signature then
    return false
  end
  self.signature = signature
  self.stops = stops
  local h, s, l = M.toHsl(self.stops[1])
  self.baseHue = h
  self.rainbowS = math.max(s, 0.55)
  self.rainbowL = math.clamp(l, 0.45, 0.75)
  self.cache = {}
  self.lists = {}
  return true
end

function Palette:setTime(seconds: number)
  if self.mode == "rainbow" and self.rainbowSpeed ~= 0 then
    self.time = seconds
    self.cache = {}
    self.lists = {}
  end
end

-- Largest per-channel difference (0..255) the current mode sweeps through, so
-- callers can split a smooth gradient into enough steps to avoid banding.
function Palette:spread(): number
  if self.mode == "solid" then
    return 0
  elseif self.mode == "rainbow" then
    return 255
  end
  local spread = 0
  for ch = 1, 3 do
    local lo, hi = 1, 0
    for _, s in ipairs(self.stops) do
      lo, hi = math.min(lo, s[ch]), math.max(hi, s[ch])
    end
    spread = math.max(spread, (hi - lo) * 255)
  end
  return spread
end

-- Fast path for drawing loops: returns (array, byLevel). When byLevel is
-- false, array[i] is the token of element i of n; when true, array[q + 1] is
-- the token for level q / M.LEVELS (see M.pick). Cached until the palette
-- refreshes, so a frame pays one lookup per element.
function Palette:colors(n: number, alphaMul: number?)
  local a = alphaMul or 1
  local byLevel = self.mode == "level"
  local key = (if byLevel then -1 else n) * 1000 + math.floor(a * 999)
  local hit = self.lists[key]
  if hit == nil then
    if byLevel then
      hit = table.create(M.LEVELS + 1)
      for q = 0, M.LEVELS do
        hit[q + 1] = self:at(1, 1, q / M.LEVELS, a)
      end
    else
      hit = table.create(n)
      for i = 1, n do
        hit[i] = self:at(i, n, 0, a)
      end
    end
    self.lists[key] = hit
  end
  return hit, byLevel
end

-- Token from a `colors()` array for element i at level v.
function M.pick(arr, byLevel: boolean, i: number, v: number): string
  if byLevel then
    local q = math.floor(v * M.LEVELS + 0.5)
    return arr[(if q < 0 then 0 elseif q > M.LEVELS then M.LEVELS else q) + 1]
  end
  return arr[i]
end

-- Does the color of an element depend on its level? (Callers can cache otherwise.)
function Palette:byLevel(): boolean
  return self.mode == "level"
end

function Palette:rgb(i: number, n: number, level: number)
  local mode = self.mode
  local t = if n > 1 then (i - 1) / (n - 1) else 0
  if mode == "solid" then
    return self.stops[1]
  elseif mode == "level" then
    return M.gradient(self.stops, level)
  elseif mode == "rainbow" then
    return M.fromHsl(self.baseHue + t * 330 + self.time * self.rainbowSpeed, self.rainbowS, self.rainbowL)
  elseif mode == "palette" then
    return self.stops[((i - 1) % #self.stops) + 1]
  end
  return M.gradient(self.stops, t) -- "gradient"
end

-- Color token for element i of n at `level`, with an extra alpha multiplier.
function Palette:at(i: number, n: number, level: number?, alphaMul: number?): string
  local a = self.alpha * (alphaMul or 1)
  local mode = self.mode
  if mode == "solid" then
    return M.token(self.tokens[1], a)
  elseif mode == "palette" then
    return M.token(self.tokens[((i - 1) % #self.tokens) + 1], a)
  end
  if mode == "level" then
    -- Quantize so neighbouring frames reuse strings.
    local q = math.floor((level or 0) * M.LEVELS + 0.5)
    local key = q * 1000 + math.floor(a * 999)
    local hit = self.cache[key]
    if hit == nil then
      hit = M.toHex(M.gradient(self.stops, q / M.LEVELS), a)
      self.cache[key] = hit
    end
    return hit
  end
  local key = (n * 4096 + i) * 1000 + math.floor(a * 999)
  local hit = self.cache[key]
  if hit == nil then
    hit = M.toHex(self:rgb(i, n, level or 0), a)
    self.cache[key] = hit
  end
  return hit
end

-- Unlit cells / tracks: the element's color at the track alpha.
function Palette:track(i: number, n: number, level: number?): string
  return self:at(i, n, level or 0, self.trackAlpha)
end

function Palette:peak(i: number, n: number, level: number): string
  if self.peakToken ~= nil then
    return M.token(self.peakToken, self.alpha)
  end
  return self:at(i, n, level)
end

-- A single representative color (for single-color controls like graphs/labels).
function Palette:primary(alphaMul: number?): string
  if self.mode == "rainbow" then
    return M.toHex(self:rgb(1, 1, 0), self.alpha * (alphaMul or 1))
  end
  return M.token(self.tokens[1], self.alpha * (alphaMul or 1))
end

function Palette:secondary(alphaMul: number?): string
  local token = self.tokens[2] or self.tokens[1]
  return M.token(token, self.alpha * (alphaMul or 1))
end

M.Palette = Palette

return M
