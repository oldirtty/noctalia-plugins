--!nonstrict

local i18n = require("./lib/i18n.luau")
local icon = require("./lib/icon.luau")

local tr = i18n.tr
local TICK_MS = 1000
local AUDIO_POLL_MS = 2000
local BRI_POLL_MS = 5000

local cfg = {
  glyph = "adjustments-horizontal",
  image = "",
  colorize = false,
  size = 16,
  tipOutput = true,
  tipInput = true,
  tipBrightness = true,
}

local state = {
  vol = nil,
  volMuted = false,
  mic = nil,
  micMuted = false,
  monitors = {}, -- { { bus, name, value }, ... }
  monitorsScanned = false,
}

local pollingAudio = false
local detectingMonitors = false
local pollingBrightness = false
local lastAudioPollMs = 0
local lastBriPollMs = 0
local lastLang: string? = nil

local render

local function reloadConfig()
  local glyph = noctalia.getConfig("glyph")
  cfg.glyph = (type(glyph) == "string" and glyph ~= "") and glyph or "adjustments-horizontal"

  local img = noctalia.getConfig("custom_image")
  cfg.image = (type(img) == "string") and img or ""

  cfg.colorize = noctalia.getConfig("colorize_custom_image") == true
  cfg.size = tonumber(noctalia.getConfig("image_size")) or 16
  cfg.tipOutput = noctalia.getConfig("tooltip_output_vol") ~= false
  cfg.tipInput = noctalia.getConfig("tooltip_input_vol") ~= false
  cfg.tipBrightness = noctalia.getConfig("tooltip_brightness") ~= false
end

-- ---------- parsing ----------

local function parseVol(s)
  local v = tonumber(string.match(s or "", "Volume:%s*([%d%.]+)"))
  local muted = string.find(s or "", "MUTED", 1, true) ~= nil
  return v and math.floor(v * 100 + 0.5) or nil, muted
end

local function parseVcp10(s)
  local cur, max = string.match(s or "", "VCP%s+10%s+%S+%s+(%d+)%s+(%d+)")
  if not cur then
    cur, max = string.match(s or "", "current value =%s*(%d+),%s*max value =%s*(%d+)")
  end
  cur, max = tonumber(cur), tonumber(max)
  if cur and max and max > 0 then
    return math.floor((cur / max) * 100 + 0.5)
  end
  return nil
end

local function parseMonitors(out)
  local found = {}
  local current = nil

  for line in string.gmatch(out or "", "[^\r\n]+") do
    local dispNum = string.match(line, "^Display%s+(%d+)")
    if dispNum then
      current = { bus = nil, drm = nil, model = nil }
      table.insert(found, current)
    elseif string.match(line, "^Invalid display") then
      current = nil
    elseif current then
      local bus = string.match(line, "I2C bus:%s*/dev/i2c%-(%d+)")
      if bus then current.bus = bus end

      local drm = string.match(line, "DRM connector:%s*(%S+)")
      if drm then
        current.drm = string.gsub(drm, "^card%d+%-", "")
      end

      local mon = string.match(line, "Monitor:%s*(.+)$")
      if mon then
        local _, model = string.match(mon, "^([^:]*):([^:]*)")
        model = model and noctalia.string.trim(model) or ""
        if model ~= "" then current.model = model end
      end
    end
  end

  local prevByBus = {}
  for _, old in ipairs(state.monitors) do
    prevByBus[old.bus] = old
  end

  local valid = {}
  for i, m in ipairs(found) do
    if m.bus then
      local prev = prevByBus[m.bus]
      table.insert(valid, {
        bus = m.bus,
        name = m.model or m.drm or ("Monitor " .. i),
        value = prev and prev.value or nil,
      })
    end
  end
  return valid
end

-- ---------- polling ----------

local function pollAudio()
  if pollingAudio or (not cfg.tipOutput and not cfg.tipInput) then
    return
  end

  local cmds = {}
  if cfg.tipOutput then
    table.insert(cmds, 'echo "vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)"')
  end
  if cfg.tipInput then
    table.insert(cmds, 'echo "mic=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null)"')
  end

  pollingAudio = true
  noctalia.runAsync(table.concat(cmds, "\n"), function(res)
    pollingAudio = false
    local stdout = (res and res.stdout) or ""
    local kv = {}
    for line in string.gmatch(stdout, "[^\n]+") do
      local k, v = string.match(line, "^([%w_]+)=(.*)$")
      if k then kv[k] = v end
    end

    local changed = false
    if kv.vol then
      local v, muted = parseVol(kv.vol)
      if v ~= state.vol or muted ~= state.volMuted then
        state.vol = v
        state.volMuted = muted
        changed = true
      end
    end
    if kv.mic then
      local m, muted = parseVol(kv.mic)
      if m ~= state.mic or muted ~= state.micMuted then
        state.mic = m
        state.micMuted = muted
        changed = true
      end
    end

    if changed then
      render()
    end
  end)
end

local function readMonitorsBrightness()
  if pollingBrightness or #state.monitors == 0 then
    return
  end

  local syncAll = noctalia.getSetting("brightness.sync_all_monitors") == true
  local targets = syncAll and { state.monitors[1] } or state.monitors

  local lines = {}
  for _, m in ipairs(targets) do
    table.insert(lines, string.format(
      '(echo "bri_%s=$(ddcutil --bus=%s --sleep-multiplier=.1 getvcp 10 --brief 2>/dev/null)") &',
      m.bus, m.bus
    ))
  end
  table.insert(lines, "wait")

  pollingBrightness = true
  noctalia.runAsync(table.concat(lines, "\n"), function(res)
    pollingBrightness = false
    local stdout = (res and res.stdout) or ""
    local kv = {}
    for line in string.gmatch(stdout, "[^\n]+") do
      local k, v = string.match(line, "^([%w_]+)=(.*)$")
      if k then kv[k] = v end
    end

    local changed = false
    local syncedPct = nil

    for _, mon in ipairs(targets) do
      local raw = kv["bri_" .. mon.bus]
      if raw then
        local pct = parseVcp10(raw)
        if pct and pct ~= mon.value then
          mon.value = pct
          changed = true
        end
        if pct then
          syncedPct = syncedPct or pct
        end
      end
    end

    if syncAll and syncedPct then
      for _, mon in ipairs(state.monitors) do
        if mon.value ~= syncedPct then
          mon.value = syncedPct
          changed = true
        end
      end
    end

    if changed then
      render()
    end
  end)
end

local function pollBrightness()
  if not cfg.tipBrightness then
    return
  end

  if not state.monitorsScanned then
    if detectingMonitors then return end
    detectingMonitors = true
    noctalia.runAsync({ "ddcutil", "detect", "--brief", "--sleep-multiplier=.1" }, function(res)
      detectingMonitors = false
      state.monitors = parseMonitors((res and res.stdout) or "")
      state.monitorsScanned = true
      readMonitorsBrightness()
      render()
    end)
  else
    readMonitorsBrightness()
  end
end

-- ---------- tooltip & render ----------

local function formatVolValue(val, muted)
  if val == nil then
    return "--"
  end
  if muted then
    return tostring(val) .. "% (" .. tr("core.muted") .. ")"
  end
  return tostring(val) .. "%"
end

local function buildTooltip()
  local rows = {}

  if cfg.tipOutput then
    table.insert(rows, { tr("core.tooltip.output_vol"), formatVolValue(state.vol, state.volMuted) })
  end

  if cfg.tipInput then
    table.insert(rows, { tr("core.tooltip.input_vol"), formatVolValue(state.mic, state.micMuted) })
  end

  if cfg.tipBrightness then
    if #state.monitors > 0 then
      for _, mon in ipairs(state.monitors) do
        local valStr = mon.value ~= nil and (tostring(mon.value) .. "%") or "--"
        table.insert(rows, { mon.name, valStr })
      end
    else
      table.insert(rows, { tr("core.brightness"), "--" })
    end
  end

  if #rows == 0 then
    return tr("core.title")
  end
  return rows
end

render = function()
  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({
    key = "root",
    align = "center",
    justify = "center",
  }, {
    icon.node(cfg, render),
  }))
  barWidget.setTooltip(buildTooltip())
end

-- ---------- callbacks ----------

function onClick()
  noctalia.togglePanel("oldirtty/core:panel")
end

function onConfigChanged()
  reloadConfig()
  lastAudioPollMs = 0
  lastBriPollMs = 0
  pollAudio()
  pollBrightness()
  render()
end

function update()
  local now = noctalia.nowMs()
  local curLang = i18n.lang()
  local langChanged = curLang ~= lastLang
  lastLang = curLang

  if (cfg.tipOutput or cfg.tipInput) and (now - lastAudioPollMs >= AUDIO_POLL_MS) then
    lastAudioPollMs = now
    pollAudio()
  end

  if cfg.tipBrightness and (now - lastBriPollMs >= BRI_POLL_MS) then
    lastBriPollMs = now
    pollBrightness()
  end

  if langChanged then
    render()
  end
end

-- ---------- start ----------

reloadConfig()
lastLang = i18n.lang()
noctalia.setUpdateInterval(TICK_MS)
pollAudio()
pollBrightness()
render()
