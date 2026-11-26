--!nonstrict
-- Fullscreen watcher shared by the bar and desktop entries.
--
-- Subscribes to the compositor's window snapshots through
-- noctalia.compositor.subscribe and reports whether a visible fullscreen
-- window sits on the widget's output. Umbriel sends full snapshots ("windows"
-- event, an array of windows with `fullscreen`, `visible`, `minimized` and
-- `output`); other compositors are accepted when their payload has the same
-- shape (`is_fullscreen` is read as well). When the compositor is unsupported
-- the watcher stays inert and the widget never pauses.

local M = {}

local function windowList(data)
  if type(data) ~= "table" then
    return nil
  end
  if type(data.windows) == "table" then
    return data.windows
  end
  if type(data.data) == "table" then
    return data.data
  end
  if data[1] ~= nil or next(data) == nil then
    return data
  end
  return nil
end

-- True when `windows` holds a visible, non-minimized fullscreen window on
-- `output` (any output when `output` or the window's output is unknown).
function M.fullscreenOn(windows, output: string?): boolean
  for _, w in ipairs(windows) do
    if type(w) == "table" then
      local full = w.fullscreen == true or w.is_fullscreen == true
      local shown = w.visible ~= false and w.minimized ~= true
      local here = output == nil or w.output == nil or w.output == output
      if full and shown and here then
        return true
      end
    end
  end
  return false
end

-- opts:
--   subscribe(options, cb) -> id | nil   (defaults to noctalia.compositor.subscribe)
--   outputName() -> string | nil         (the widget's output, read per snapshot)
--   onChange(active: boolean)            (called only when the state flips)
--   log(msg)
-- Returns the watcher, or nil when subscribing is impossible.
function M.watch(opts)
  local subscribe = opts.subscribe
  if subscribe == nil then
    local comp = if noctalia ~= nil then noctalia.compositor else nil
    if type(comp) ~= "table" or type(comp.subscribe) ~= "function" then
      if opts.log then
        opts.log("spectra: noctalia.compositor.subscribe is unavailable; pause while fullscreen is inactive")
      end
      return nil
    end
    subscribe = function(options, cb)
      return comp.subscribe(options, cb)
    end
  end

  local self = { active = false }

  local function onEvent(event, data)
    if type(event) == "string" and not string.find(string.lower(event), "window", 1, true) then
      return
    end
    local windows = windowList(data)
    if windows == nil then
      return
    end
    local output = nil
    if opts.outputName ~= nil then
      local ok, name = pcall(opts.outputName)
      if ok and type(name) == "string" and name ~= "" then
        output = name
      end
    end
    local active = M.fullscreenOn(windows, output)
    if active ~= self.active then
      self.active = active
      opts.onChange(active)
    end
  end

  local ok, id = pcall(subscribe, { events = { "windows" } }, onEvent)
  if not ok or id == nil then
    if opts.log then
      opts.log("spectra: compositor window events unavailable (" .. tostring(id) .. "); pause while fullscreen is inactive")
    end
    return nil
  end
  self.id = id
  self.onEvent = onEvent -- exposed for the self-test
  return self
end

return M
