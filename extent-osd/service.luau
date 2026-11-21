--!nonstrict
-- Extent OSD service.
--
-- Holds `umbriel subscribe windows,workspaces,outputs` open. Every `windows`
-- line is a full snapshot carrying final geometry (keyboard/IPC extent actions
-- produce one snapshot; mouse resizes stream one per motion), so a resize shows
-- up as a snapshot where the focused window kept its identity and context but
-- its w/h changed. That is the trigger.
--
-- Labels name the on-screen side that changed (Width / Height) rather than
-- Umbriel's primary / secondary roles, so they are right on any layout and on
-- rotated (portrait) outputs without knowing the output's workspace_axis.
-- Percentages are measured against the matching side of the output's usable
-- area, oriented using the output's transform.

local RECONNECT_INTERVAL_MS = 1000
local DISCONNECT_EVENT = "extent-osd-disconnected"
-- runStream has no exit callback; the trailer line tells us the child exited.
local STREAM_COMMAND = [[umbriel subscribe windows,workspaces,outputs; printf '\n{"event":"]]
  .. DISCONNECT_EVENT
  .. [["}\n']]

local streaming = false
local workspaces = {} -- id -> workspace
local outputs = {} -- name -> output
local last = nil -- { id, w, h, context } of the last focused window seen
-- nowMs() of the latest width / height change on the tracked window. A mouse
-- drag emits a snapshot per motion and many of them move only one axis, so
-- the popup would flip between the width, height and combined forms. Showing
-- the combined form while both axes changed within combine_window_ms keeps it
-- steady for the whole drag.
local lastWidthChangeMs = -math.huge
local lastHeightChangeMs = -math.huge

-- Same fallback the umbriel CLI uses, so we only connect once the socket exists.
local function socketPath()
  local explicit = noctalia.getenv("UMBRIEL_SOCKET")
  if explicit ~= nil and explicit ~= "" then
    return explicit
  end
  local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
  local display = noctalia.getenv("WAYLAND_DISPLAY")
  if runtimeDir ~= nil and runtimeDir ~= "" and display ~= nil and display ~= "" then
    return `{runtimeDir}/umbriel-{display}.sock`
  end
  return nil
end

local function configInt(key, fallback)
  local value = tonumber(noctalia.getConfig(key))
  if value == nil then
    return fallback
  end
  return value
end

local function isRotated(output)
  local transform = tostring(output.transform or "normal")
  return transform:find("90", 1, true) ~= nil or transform:find("270", 1, true) ~= nil
end

-- Usable area of an output in window (logical) coordinates: { width, height,
-- portrait }. Umbriel reports logical, already-rotated sizes; if a rotated
-- output's usable area ever disagrees with its logical orientation (i.e. came
-- through in mode coordinates), swap it so width always means on-screen width.
local function outputArea(output)
  if output == nil then
    return nil
  end
  local logical = output.logical_size
  local usable = output.usable_area or logical
  if type(usable) ~= "table" or type(usable.width) ~= "number" or type(usable.height) ~= "number" then
    return nil
  end
  local width, height = usable.width, usable.height
  if isRotated(output) and type(logical) == "table" and type(logical.width) == "number" then
    local logicalPortrait = logical.height > logical.width
    if (height > width) ~= logicalPortrait then
      width, height = height, width
    end
  end
  return { width = width, height = height, portrait = height > width }
end

-- `active` marks the window holding keyboard focus; when a Noctalia surface
-- has focus nothing is active, so fall back to the focused workspace's window.
local function findFocusedWindow(windows)
  for _, window in ipairs(windows) do
    if window.active == true then
      return window
    end
  end
  for _, workspace in pairs(workspaces) do
    if workspace.focused == true then
      for _, window in ipairs(windows) do
        if window.focused == true and window.workspace == workspace.id then
          return window
        end
      end
    end
  end
  return nil
end

-- Everything that, when it changes, resizes a window without an extent change:
-- moving between workspaces/outputs/columns, (un)floating, fullscreen,
-- maximize, tabbing, title bar toggles, layout switches, windows opening or
-- closing on the same workspace, and output reconfiguration or rotation.
local function contextKey(window, windows)
  local siblings = {}
  for _, other in ipairs(windows) do
    if other.workspace == window.workspace then
      table.insert(siblings, other.id)
    end
  end
  table.sort(siblings)

  local workspace = workspaces[window.workspace]
  local output = outputs[window.output]
  local area = outputArea(output)

  return table.concat({
    tostring(window.workspace),
    tostring(window.output),
    tostring(window.floating),
    tostring(window.fullscreen),
    tostring(window.maximized),
    tostring(window.maximized_to_edges),
    tostring(window.minimized),
    tostring(window.tabbed),
    tostring(window.title_bar),
    tostring(window.column),
    tostring(window.row),
    tostring(window.region ~= nil),
    workspace ~= nil and tostring(workspace.layout) or "?",
    output ~= nil and tostring(output.transform) or "?",
    area ~= nil and `{area.width}x{area.height}` or "?",
    table.concat(siblings, ","),
  }, "|")
end

-- Extent fraction of a tiled window side, or nil when the output is unknown:
-- fraction * (viewport + gap) - gap = outer size, viewport = usable - 2 gap.
local function fractionFor(window, horizontal)
  local area = outputArea(outputs[window.output])
  if area == nil then
    return nil
  end
  local border = configInt("border_width", 2)
  local outer
  local available
  if horizontal then
    outer = window.w + 2 * border
    available = area.width
  else
    local titleBar = window.title_bar == true and configInt("title_bar_height", 28) or 0
    outer = window.h + 2 * border + titleBar
    available = area.height
  end
  if available <= 0 then
    return nil
  end
  local gap = configInt("gap", 8)
  local viewport = available - 2 * gap
  if viewport + gap <= 0 then
    return nil
  end
  return (outer + gap) / (viewport + gap)
end

-- Tiled windows are sized as a share of the output, so show the percentage
-- (with a progress bar). Floating windows have free sizes, so show pixels.
local function describeSide(window, horizontal)
  local label = noctalia.tr(horizontal and "osd.width" or "osd.height")
  local px = horizontal and window.w or window.h
  if window.floating == true then
    return `{label} {px}px`, nil
  end
  local fraction = fractionFor(window, horizontal)
  local text
  if fraction ~= nil then
    text = `{label} {math.floor(fraction * 100 + 0.5)}%`
    if noctalia.getConfig("show_pixels") == true then
      text ..= ` ({px}px)`
    end
  else
    text = `{label} {px}px`
  end
  return text, fraction
end

local function showOsd(window, widthChanged, heightChanged)
  if widthChanged and heightChanged then
    -- Noctalia's OSD pill has a fixed width (~25 characters of text) that
    -- plugins can't change, so "Width 1200px · Height 1200px" would be cut
    -- off. Use width × height notation; the diagonal icon names both axes.
    local text
    local widthFraction = window.floating ~= true and fractionFor(window, true) or nil
    local heightFraction = window.floating ~= true and fractionFor(window, false) or nil
    if widthFraction ~= nil and heightFraction ~= nil then
      text = `{math.floor(widthFraction * 100 + 0.5)}% × {math.floor(heightFraction * 100 + 0.5)}%`
    else
      text = `{window.w} × {window.h} px`
    end
    noctalia.osd.show("arrows-diagonal", text)
    return
  end
  local text, fraction = describeSide(window, widthChanged)
  local icon = widthChanged and "arrows-horizontal" or "arrows-vertical"
  if fraction ~= nil then
    noctalia.osd.show(icon, text, { progress = math.clamp(fraction, 0, 1) })
  else
    noctalia.osd.show(icon, text)
  end
end

local function onWindows(windows)
  local window = findFocusedWindow(windows)
  if window == nil or type(window.w) ~= "number" or type(window.h) ~= "number" then
    last = nil
    return
  end

  local context = contextKey(window, windows)
  local previous = last
  last = { id = window.id, w = window.w, h = window.h, context = context }

  if previous == nil or previous.id ~= window.id or previous.context ~= context then
    lastWidthChangeMs = -math.huge
    lastHeightChangeMs = -math.huge
    return
  end
  if window.floating == true and noctalia.getConfig("include_floating") ~= true then
    return
  end
  if window.fullscreen == true or window.minimized == true then
    return
  end

  local threshold = configInt("min_change_px", 2)
  local widthChanged = math.abs(window.w - previous.w) >= threshold
  local heightChanged = math.abs(window.h - previous.h) >= threshold
  if not widthChanged and not heightChanged then
    return
  end

  local now = noctalia.nowMs()
  if widthChanged then
    lastWidthChangeMs = now
  end
  if heightChanged then
    lastHeightChangeMs = now
  end
  local combineWindow = configInt("combine_window_ms", 300)
  local showWidth = now - lastWidthChangeMs <= combineWindow
  local showHeight = now - lastHeightChangeMs <= combineWindow
  showOsd(window, showWidth, showHeight)
end

local function onLine(line)
  local decoded = noctalia.json.decode(line)
  if type(decoded) ~= "table" then
    return
  end
  if decoded.event == DISCONNECT_EVENT then
    streaming = false
    last = nil
    return
  end
  if type(decoded.err) == "string" then
    noctalia.log("extent-osd: umbriel subscribe rejected: " .. decoded.err)
    return
  end
  if type(decoded.data) ~= "table" then
    return
  end

  if decoded.event == "workspaces" then
    workspaces = {}
    for _, workspace in ipairs(decoded.data) do
      workspaces[workspace.id] = workspace
    end
  elseif decoded.event == "outputs" then
    outputs = {}
    for _, output in ipairs(decoded.data) do
      outputs[output.name] = output    end
  elseif decoded.event == "windows" then
    onWindows(decoded.data)
  end
end

local function startStream()
  if streaming then
    return
  end
  local path = socketPath()
  if path == nil or not noctalia.fileExists(path) or not noctalia.commandExists("umbriel") then
    return
  end
  last = nil
  streaming = noctalia.runStream(STREAM_COMMAND, onLine)
end

function update()
  startStream()
end

function onIpc(event, _payload)
  -- `noctalia msg plugin kylex/extent-osd:service all test` previews the popup.
  if event == "test" then
    noctalia.osd.show("arrows-horizontal", `{noctalia.tr("osd.width")} 50%`, { progress = 0.5 })
  end
end

noctalia.setUpdateInterval(RECONNECT_INTERVAL_MS)
startStream()
