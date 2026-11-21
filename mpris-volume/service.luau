--!nonstrict
-- MPRIS Volume service.
--
-- Drives one MPRIS player via playerctl, triggered from the shell. Shows no
-- UI of its own; problems go to the Noctalia log.
--
--   noctalia msg plugin kylex/mpris-volume:service all up [step|player=NAME]
--   noctalia msg plugin kylex/mpris-volume:service all down [step|player=NAME]
--   noctalia msg plugin kylex/mpris-volume:service all set <percent> [player=NAME]
--   noctalia msg plugin kylex/mpris-volume:service all mute [player=NAME]
--   noctalia msg plugin kylex/mpris-volume:service all play|pause|toggle|next|previous|stop [player=NAME]
--   noctalia msg plugin kylex/mpris-volume:service all seek <seconds, negative = back> [player=NAME]
--
-- `previous` rewinds to the start of the track when more than
-- restart_threshold seconds in, and only skips back when near the start.
--
-- Payload tokens are whitespace separated and order-free: a bare number is the
-- step / target percent / seconds, `player=NAME` overrides the configured player.
--
-- Volume commands act on the player's own Volume property (not the system
-- mixer). Each reads the current volume and writes an absolute value, rather
-- than using playerctl's relative `0.05+`, so it can clamp to max_volume.
-- Holding a key fires commands faster than the read-back round trip, so the
-- last value we wrote is reused as the base for a short while instead of
-- re-reading a value the player may not have applied yet.

local CACHE_MS = 1500
local TIMEOUT_MS = 2000
local DEFAULT_UNMUTE = 0.5

local cache = {} -- player spec -> { volume, at }
local unmuteVolume = {} -- player spec -> volume before mute

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

local function log(message)
  noctalia.log("mpris-volume: " .. message)
end

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

-- Runs `playerctl -p spec <extra...>`; calls onSuccess(stdout) on exit 0,
-- otherwise logs why it failed.
local function playerctl(spec, extra, what, onSuccess)
  local argv = { "playerctl", "-p", spec }
  for _, arg in ipairs(extra) do
    table.insert(argv, arg)
  end
  local started = noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      cache[spec] = nil
      local err = noctalia.string.trim(result.stderr or "")
      if err:find("No players found", 1, true) then
        log(`{what}: {spec} not running`)
      else
        log(`{what} on {spec} failed: {err}`)
      end
      return
    end
    if onSuccess ~= nil then
      onSuccess(noctalia.string.trim(result.stdout or ""))
    end
  end, TIMEOUT_MS)
  if not started then
    log("could not run playerctl")
  end
end

local function readVolume(spec, what, callback)
  local entry = cache[spec]
  if entry ~= nil and noctalia.nowMs() - entry.at <= CACHE_MS then
    callback(entry.volume)
    return
  end
  playerctl(spec, { "volume" }, what, function(out)
    local volume = tonumber(out)
    if volume == nil then
      log(`{what}: {spec} has no volume control`)
      return
    end
    callback(volume)
  end)
end

local function writeVolume(spec, what, volume)
  local maxVolume = configInt("max_volume", 100) / 100
  volume = math.clamp(volume, 0, maxVolume)
  -- Round to whole percents so repeated steps land on clean values.
  volume = math.floor(volume * 100 + 0.5) / 100
  cache[spec] = { volume = volume, at = noctalia.nowMs() }
  playerctl(spec, { "volume", string.format("%.2f", volume) }, what)
end

function onIpc(event, payload)
  local args = parsePayload(payload)
  local spec = args.player or configuredPlayer()
  if spec == "" then
    log("no player configured")
    return
  end

  if event == "previous" or event == "prev" then
    -- Like most players' back button: past restart_threshold seconds into the
    -- track, rewind to its start; near the start, go to the previous track.
    local threshold = configInt("restart_threshold", 3)
    playerctl(spec, { "position" }, event, function(out)
      local position = tonumber(out)
      if position ~= nil and threshold > 0 and position > threshold then
        playerctl(spec, { "position", "0" }, event)
      else
        playerctl(spec, { "previous" }, event)
      end
    end)
  elseif MEDIA_COMMANDS[event] ~= nil then
    playerctl(spec, { MEDIA_COMMANDS[event] }, event)
  elseif event == "seek" then
    if args.value == nil or args.value == 0 then
      log("seek needs seconds, e.g. `seek 10` or `seek -10`")
      return
    end
    local sign = args.value > 0 and "+" or "-"
    playerctl(spec, { "position", tostring(math.abs(args.value)) .. sign }, event)
  elseif event == "up" or event == "down" then
    local step = (args.value or configInt("step", 5)) / 100
    if event == "down" then
      step = -step
    end
    readVolume(spec, event, function(volume)
      writeVolume(spec, event, volume + step)
    end)
  elseif event == "set" then
    if args.value == nil then
      log("set needs a percent, e.g. `set 40`")
      return
    end
    writeVolume(spec, event, args.value / 100)
  elseif event == "mute" then
    readVolume(spec, event, function(volume)
      if volume > 0 then
        unmuteVolume[spec] = volume
        writeVolume(spec, event, 0)
      else
        writeVolume(spec, event, unmuteVolume[spec] or DEFAULT_UNMUTE)
      end
    end)
  else
    log(`unknown event '{tostring(event)}' (use up, down, set, mute, play, pause, toggle, next, previous, stop, seek)`)
  end
end
