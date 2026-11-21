--!nonstrict
-- MPRIS Volume service.
--
-- Drives one MPRIS player's own volume property (org.mpris.MediaPlayer2.Player
-- .Volume) via playerctl, triggered from the shell:
--
--   noctalia msg plugin kylex/mpris-volume:service all up [step|player=NAME]
--   noctalia msg plugin kylex/mpris-volume:service all down [step|player=NAME]
--   noctalia msg plugin kylex/mpris-volume:service all set <percent> [player=NAME]
--   noctalia msg plugin kylex/mpris-volume:service all mute [player=NAME]
--   noctalia msg plugin kylex/mpris-volume:service all show [player=NAME]
--   noctalia msg plugin kylex/mpris-volume:service all play|pause|toggle|next|previous|stop [player=NAME]
--   noctalia msg plugin kylex/mpris-volume:service all seek <seconds, negative = back> [player=NAME]
--
-- Payload tokens are whitespace separated and order-free: a bare number is the
-- step / target percent, `player=NAME` overrides the configured player.
--
-- Each command reads the current volume and writes an absolute value, rather
-- than using playerctl's relative `0.05+`, so it can clamp to max_volume.
-- Holding a key fires commands faster than the read-back round trip, so the
-- last value we wrote is reused as the base for a short while instead of
-- re-reading a value the player may not have applied yet.

local CACHE_MS = 1500
local TIMEOUT_MS = 2000
local DEFAULT_UNMUTE = 0.5

local cache = {} -- player spec -> { volume, name, at }
local unmuteVolume = {} -- player spec -> volume before mute

local function configInt(key, fallback)
  local value = tonumber(noctalia.getConfig(key))
  if value == nil then
    return fallback
  end
  return value
end

local function configuredPlayer()
  local player = noctalia.getConfig("player")
  if type(player) ~= "string" then
    return ""
  end
  return (player:gsub("%s+", ""))
end

local function parsePayload(payload)
  local args = { value = nil, player = nil }
  if payload == nil then
    return args
  end
  for token in tostring(payload):gmatch("%S+") do
    local name = token:match("^player=(.+)$")
    if name ~= nil then
      args.player = name
    elseif tonumber(token) ~= nil then
      args.value = tonumber(token)
    end
  end
  return args
end

local function osdIcon(volume)
  if volume <= 0 then
    return "volume-3"
  elseif volume < 0.5 then
    return "volume-2"
  end
  return "volume"
end

local function showVolume(name, volume)
  if noctalia.getConfig("show_osd") ~= true then
    return
  end
  local percent = math.floor(volume * 100 + 0.5)
  local text
  if percent <= 0 then
    text = noctalia.tr("osd.muted", { player = name })
  else
    text = noctalia.tr("osd.volume", { player = name, percent = percent })
  end
  local maxVolume = math.max(configInt("max_volume", 100), 100) / 100
  noctalia.osd.show(osdIcon(volume), text, { progress = math.clamp(volume / maxVolume, 0, 1) })
end

local function showError(key, name)
  noctalia.log(`mpris-volume: {noctalia.tr(key, { player = name })}`)
  if noctalia.getConfig("show_osd") == true then
    noctalia.osd.show("volume-off", noctalia.tr(key, { player = name }))
  end
end

-- Calls back with (name, volume) for the player, or reports why it can't.
local function readVolume(spec, callback)
  local entry = cache[spec]
  if entry ~= nil and noctalia.nowMs() - entry.at <= CACHE_MS then
    callback(entry.name, entry.volume)
    return
  end
  local argv = { "playerctl", "-p", spec, "status", "--format", "{{playerName}}|{{volume}}" }
  local started = noctalia.runAsync(argv, function(result)
    local out = noctalia.string.trim(result.stdout or "")
    local name, raw = out:match("^(.-)|(.*)$")
    if result.exitCode ~= 0 or name == nil then
      cache[spec] = nil
      showError("osd.not_found", spec)
      return
    end
    local volume = tonumber(raw)
    if volume == nil then
      showError("osd.no_volume", name)
      return
    end
    callback(name, volume)
  end, TIMEOUT_MS)
  if not started then
    noctalia.log("mpris-volume: could not run playerctl")
  end
end

local function writeVolume(spec, name, volume)
  local maxVolume = configInt("max_volume", 100) / 100
  volume = math.clamp(volume, 0, maxVolume)
  -- Round to whole percents so repeated steps land on clean values.
  volume = math.floor(volume * 100 + 0.5) / 100
  cache[spec] = { volume = volume, name = name, at = noctalia.nowMs() }
  showVolume(name, volume)
  local argv = { "playerctl", "-p", spec, "volume", string.format("%.2f", volume) }
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      cache[spec] = nil
      noctalia.log(`mpris-volume: setting {name} volume failed: {noctalia.string.trim(result.stderr or "")}`)
    end
  end, TIMEOUT_MS)
end

-- Transport commands: event -> playerctl subcommand. All of them go through
-- `-p spec`, so they only ever touch the configured player, never whichever
-- player playerctl / Noctalia currently considers active.
local MEDIA_COMMANDS = {
  play = "play",
  pause = "pause",
  toggle = "play-pause",
  ["play-pause"] = "play-pause",
  next = "next",
  previous = "previous",
  prev = "previous",
  stop = "stop",
}

local STATUS_ICONS = {
  Playing = "player-play",
  Paused = "player-pause",
  Stopped = "player-stop",
}

local TRACK_FORMAT = "{{playerName}}|{{status}}|{{title}}"

-- After next / previous the player needs a moment to publish the new track's
-- metadata, so the read-back waits a little before showing the OSD.
local function showTrack(spec, event)
  if noctalia.getConfig("show_osd") ~= true then
    return
  end
  local skipping = event == "next" or event == "previous" or event == "prev"
  local delay = skipping and "0.4" or "0.1"
  -- spec and format go in as positional args, never spliced into the script.
  local argv = {
    "sh",
    "-c",
    "sleep " .. delay .. '; exec playerctl -p "$1" metadata --format "$2"',
    "sh",
    spec,
    TRACK_FORMAT,
  }
  noctalia.runAsync(argv, function(result)
    local out = noctalia.string.trim(result.stdout or "")
    local name, status, title = out:match("^(.-)|(.-)|(.*)$")
    if result.exitCode ~= 0 or name == nil then
      return
    end
    local icon = STATUS_ICONS[status] or "player-play"
    if event == "next" then
      icon = "player-skip-forward"
    elseif event == "previous" or event == "prev" then
      icon = "player-skip-back"
    end
    local text = title
    if text == "" or event == "stop" then
      text = noctalia.tr("osd.status", { player = name, status = status })
    end
    noctalia.osd.show(icon, text)
  end, TIMEOUT_MS + 1000)
end

local function runMedia(spec, event, extra)
  local argv = { "playerctl", "-p", spec }
  for _, arg in ipairs(extra) do
    table.insert(argv, arg)
  end
  local started = noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      local err = noctalia.string.trim(result.stderr or "")
      if err:find("No players found", 1, true) then
        showError("osd.not_found", spec)
      else
        noctalia.log(`mpris-volume: {event} on {spec} failed: {err}`)
      end
      return
    end
    if event ~= "seek" then
      showTrack(spec, event)
    end
  end, TIMEOUT_MS)
  if not started then
    noctalia.log("mpris-volume: could not run playerctl")
  end
end

function onIpc(event, payload)
  local args = parsePayload(payload)
  local spec = args.player or configuredPlayer()
  if spec == "" then
    noctalia.log("mpris-volume: no player configured")
    return
  end

  if MEDIA_COMMANDS[event] ~= nil then
    runMedia(spec, event, { MEDIA_COMMANDS[event] })
  elseif event == "seek" then
    if args.value == nil or args.value == 0 then
      noctalia.log("mpris-volume: seek needs seconds, e.g. `seek 10` or `seek -10`")
      return
    end
    local sign = args.value > 0 and "+" or "-"
    runMedia(spec, event, { "position", tostring(math.abs(args.value)) .. sign })
  elseif event == "up" or event == "down" then
    local step = (args.value or configInt("step", 5)) / 100
    if event == "down" then
      step = -step
    end
    readVolume(spec, function(name, volume)
      writeVolume(spec, name, volume + step)
    end)
  elseif event == "set" then
    if args.value == nil then
      noctalia.log("mpris-volume: set needs a percent, e.g. `set 40`")
      return
    end
    readVolume(spec, function(name, _volume)
      writeVolume(spec, name, args.value / 100)
    end)
  elseif event == "mute" then
    readVolume(spec, function(name, volume)
      if volume > 0 then
        unmuteVolume[spec] = volume
        writeVolume(spec, name, 0)
      else
        writeVolume(spec, name, unmuteVolume[spec] or DEFAULT_UNMUTE)
      end
    end)
  elseif event == "show" then
    cache[spec] = nil
    readVolume(spec, function(name, volume)
      showVolume(name, volume)
    end)
  else
    noctalia.log(`mpris-volume: unknown event '{tostring(event)}' (use up, down, set, mute, show, play, pause, toggle, next, previous, stop, seek)`)
  end
end
