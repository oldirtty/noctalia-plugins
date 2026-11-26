--!nonstrict

-- System state and actions for Core. No UI in here.

local M = {}

local FAST_POLL = [[
echo "dflt=$(ip route show default 2>/dev/null | head -1)"
echo "vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)"
echo "mic=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null)"
echo "wifi=$(nmcli radio wifi 2>/dev/null)"
echo "bt=$(bluetoothctl show 2>/dev/null | awk '/Powered:/{print $2}')"
echo "btc=$(bluetoothctl devices Connected 2>/dev/null | wc -l)"
echo "pwr=$(powerprofilesctl get 2>/dev/null)"
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev 2>/dev/null | sed 's/^/dev=/'
]]

local AUDIO_POLL = [[
echo "vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null)"
echo "mic=$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null)"
]]

local TARGET = {
  vol = "@DEFAULT_AUDIO_SINK@",
  mic = "@DEFAULT_AUDIO_SOURCE@",
}

local CLI_STEP = {
  vol = { up = "volume-up", down = "volume-down" },
  mic = { up = "mic-volume-up", down = "mic-volume-down" },
}

local QUICK_CLI = {
  nightLight = { "noctalia", "msg", "nightlight-toggle" },
  caffeine   = { "noctalia", "msg", "caffeine-toggle" },
  dnd        = { "noctalia", "msg", "notification-dnd-toggle" },
}

local THEME_CYCLE = {
  dark  = "light",
  light = "auto",
  auto  = "dark",
}

local S = {
  vol = 0, volApplied = 0, volMuted = false,
  mic = 0, micApplied = 0, micMuted = false,
  audioReady = false,
  monitors = {}, -- { { id, bus, drm, backlight, name, value, targetPct, lastSentPct, noctaliaPct, max, ready }, ... }
  monitorsScanned = false,
  syncBrightness = true, -- always: one slider drives every monitor
  noctaliaSync = false, -- Noctalia's own brightness.sync_all_monitors
  syncTargetPct = nil,
  syncLastSentPct = nil,
  syncNoctaliaPct = nil,
  wifi = false,
  ethDev = nil,
  netMode = "none", -- ethernet | wifi | none
  net = { kind = "none", name = "" },
  bt = false, btc = 0,
  hasBattery = false,
  powerProfile = "balanced", -- power-saver | balanced | performance
  nightLight = false,
  themeMode = "dark", -- dark | light | auto
  caffeine = false,
  dnd = false,
  uptime = "",
}

M.state = S
M.dragging = {}
M.dragSince = {}
M.cooldown = {}
M.onChange = function(_fromUser) end

local lastSet = {}
local cmdInFlight = {}
local cmdDirty = {}
local cmdCallback = {}
local detectingMonitors = false
local readingBrightness = false
local readingAudio = false
local panelActive = false
local lastFastPollMs = 0
local lastBriPollMs = 0
local briSyncGen = {}

-- ---------- lock & drag helpers ----------

function M.isDragging()
  local now = noctalia.nowMs()
  for key, active in pairs(M.dragging) do
    if active then
      if now - (M.dragSince[key] or 0) > 1500 then
        M.dragging[key] = false
      else
        return true
      end
    end
  end
  return false
end

local function isLocked(key)
  if M.dragging[key] then
    if noctalia.nowMs() - (M.dragSince[key] or 0) <= 1500 then
      return true
    end
    M.dragging[key] = false
  end
  local untilMs = M.cooldown[key]
  return untilMs ~= nil and noctalia.nowMs() < untilMs
end

local function isAnyBrightnessBusy()
  if cmdInFlight["bri_all"] or cmdInFlight["noctalia_bri_all"] or isLocked("bri_all") then
    return true
  end
  for _, mon in ipairs(S.monitors) do
    local key = "bri_" .. mon.bus
    local nkey = "noctalia_bri_" .. mon.bus
    if cmdInFlight[key] or cmdInFlight[nkey] or isLocked(key) then
      return true
    end
  end
  return false
end

-- ---------- Noctalia settings & state readers ----------

local function readJsonFiles()
  local files = {}
  local paths = {
    "~/.config/noctalia/settings.json",
    "~/.local/state/noctalia/state.json",
    "~/.local/state/noctalia/shell-state.json",
  }
  for _, p in ipairs(paths) do
    local expanded = noctalia.expandPath(p)
    local raw = expanded and noctalia.readFile(expanded)
    if raw then
      table.insert(files, raw)
    end
  end
  return files
end

local function queryBool(settingKeys, jsonBlocks, jsonKeys, rawDocs)
  for _, k in ipairs(settingKeys) do
    local val = noctalia.getSetting(k)
    if type(val) == "boolean" then
      return val
    end
  end

  for _, raw in ipairs(rawDocs) do
    for _, blockName in ipairs(jsonBlocks) do
      local block = string.match(raw, '"' .. blockName .. '"%s*:%s*(%b{})')
      if block then
        for _, jk in ipairs(jsonKeys) do
          local s = string.match(block, '"' .. jk .. '"%s*:%s*(%a+)')
          if s == "true" then return true end
          if s == "false" then return false end
        end
      end
    end
    for _, jk in ipairs(jsonKeys) do
      local s = string.match(raw, '"' .. jk .. '"%s*:%s*(%a+)')
      if s == "true" then return true end
      if s == "false" then return false end
    end
  end

  return nil
end

local function queryString(settingKeys, jsonBlocks, jsonKeys, rawDocs)
  for _, k in ipairs(settingKeys) do
    local val = noctalia.getSetting(k)
    if type(val) == "string" and val ~= "" then
      return val
    end
  end

  for _, raw in ipairs(rawDocs) do
    for _, blockName in ipairs(jsonBlocks) do
      local block = string.match(raw, '"' .. blockName .. '"%s*:%s*(%b{})')
      if block then
        for _, jk in ipairs(jsonKeys) do
          local s = string.match(block, '"' .. jk .. '"%s*:%s*"([^"]+)"')
          if s and s ~= "" then return s end
        end
      end
    end
    for _, jk in ipairs(jsonKeys) do
      local s = string.match(raw, '"' .. jk .. '"%s*:%s*"([^"]+)"')
      if s and s ~= "" then return s end
    end
  end

  return nil
end

local function readSyncBrightnessSetting(docs)
  local val = queryBool(
    { "brightness.sync_all_monitors" },
    { "brightness" },
    { "sync_all_monitors" },
    docs
  )
  return val == true
end

local function readQuickStates(docs)
  if not isLocked("nightLight") then
    local nlState = noctalia.nightlight and noctalia.nightlight.state()
    if nlState and type(nlState.enabled) == "boolean" then
      S.nightLight = nlState.enabled
    else
      local v = queryBool(
        { "nightLight.enabled", "night_light.enabled", "nightLight.active", "night_light.active" },
        { "nightLight", "night_light" },
        { "enabled", "active" },
        docs
      )
      if v ~= nil then S.nightLight = v end
    end
  end

  if not isLocked("themeMode") then
    local mode = queryString(
      { "colorSchemes.themeMode", "colorSchemes.theme_mode", "appearance.themeMode", "general.themeMode", "themeMode", "theme_mode" },
      { "colorSchemes", "appearance", "general", "theme" },
      { "themeMode", "theme_mode" },
      docs
    )
    if mode == "dark" or mode == "light" or mode == "auto" then
      S.themeMode = mode
    elseif type(noctalia.isDarkMode) == "function" then
      S.themeMode = noctalia.isDarkMode() and "dark" or "light"
    end
  end

  if not isLocked("caffeine") then
    local v = queryBool(
      { "caffeine.enabled", "caffeine.active", "general.caffeine", "caffeine" },
      { "caffeine", "idle" },
      { "enabled", "active", "inhibit", "caffeine" },
      docs
    )
    if v ~= nil then S.caffeine = v end
  end

  if not isLocked("dnd") then
    local v = queryBool(
      { "notifications.doNotDisturb", "notifications.do_not_disturb", "notifications.dnd", "dnd.enabled", "doNotDisturb" },
      { "notifications", "dnd" },
      { "doNotDisturb", "do_not_disturb", "dnd", "enabled" },
      docs
    )
    if v ~= nil then S.dnd = v end
  end
end

-- ---------- coalesced runner ----------

local function runCoalesced(key, buildCmd, onDone)
  if onDone then
    cmdCallback[key] = onDone
  end
  if cmdInFlight[key] then
    cmdDirty[key] = true
    return
  end

  local cmd = buildCmd()
  if not cmd then
    local cb = cmdCallback[key]
    cmdCallback[key] = nil
    if cb then cb() end
    return
  end

  cmdInFlight[key] = true
  cmdDirty[key] = false

  noctalia.runAsync(cmd, function()
    cmdInFlight[key] = false
    if cmdDirty[key] then
      cmdDirty[key] = false
      runCoalesced(key, buildCmd, nil)
    else
      local cb = cmdCallback[key]
      cmdCallback[key] = nil
      if cb then cb() end
    end
  end)
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
  if not cur then
    cur, max = string.match(s or "", "^%s*(%d+)%s+(%d+)%s*$")
  end
  cur, max = tonumber(cur), tonumber(max)
  if cur and max and max > 0 then
    return math.floor((cur / max) * 100 + 0.5), max
  end
  return nil, nil
end

local function scanBacklights()
  local found = {}
  local entries = noctalia.listDir("/sys/class/backlight") or {}
  for _, name in ipairs(entries) do
    local base = "/sys/class/backlight/" .. name
    local cur = tonumber(noctalia.string.trim(noctalia.readFile(base .. "/brightness") or ""))
    local max = tonumber(noctalia.string.trim(noctalia.readFile(base .. "/max_brightness") or ""))
    if cur and max and max > 0 then
      local pct = math.floor((cur / max) * 100 + 0.5)
      table.insert(found, {
        id = "bl-" .. name,
        bus = "bl-" .. name,
        drm = nil,
        backlight = name,
        name = name,
        value = pct,
        targetPct = pct,
        lastSentPct = pct,
        noctaliaPct = pct,
        max = max,
        ready = true,
      })
    end
  end
  return found
end

local function parseMonitors(out)
  local found = {}
  local current = nil

  for line in string.gmatch(out or "", "[^\r\n]+") do
    local dispNum = string.match(line, "^Display%s+(%d+)")
    if dispNum then
      current = { num = dispNum, bus = nil, drm = nil, model = nil }
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
  for _, old in ipairs(S.monitors) do
    prevByBus[old.bus] = old
  end

  local valid = {}
  for i, m in ipairs(found) do
    if m.bus then
      local prev = prevByBus[m.bus]
      table.insert(valid, {
        id = "bus-" .. m.bus,
        bus = m.bus,
        drm = m.drm or (prev and prev.drm),
        backlight = nil,
        name = m.model or m.drm or ("Monitor " .. i),
        value = prev and prev.value or 50,
        targetPct = prev and prev.targetPct or nil,
        lastSentPct = prev and prev.lastSentPct or nil,
        noctaliaPct = prev and prev.noctaliaPct or nil,
        max = prev and prev.max or 100,
        ready = prev and prev.ready or false,
      })
    end
  end
  return valid
end

local function formatUptime(seconds)
  local d = math.floor(seconds / 86400)
  local h = math.floor((seconds % 86400) / 3600)
  local m = math.floor((seconds % 3600) / 60)
  if d > 0 then
    return string.format("%dd %dh %dm", d, h, m)
  end
  return string.format("%dh %dm", h, m)
end

local function analyzeNet(devs, defaultDev, wifiEnabled)
  local ethDev = nil
  local ethConnected = nil
  local wifiConnected = nil

  for _, d in ipairs(devs) do
    if d.kind == "ethernet" then
      local isConn = string.sub(d.state, 1, 9) == "connected" or d.state == "connecting"
      local isAvail = isConn or d.state == "disconnected"
      if isAvail and not ethDev then
        ethDev = d.device
      end
      if isConn then
        if not ethConnected or d.device == defaultDev then
          ethConnected = d
          ethDev = d.device
        end
      end
    elseif d.kind == "wifi" then
      local isConn = string.sub(d.state, 1, 9) == "connected" or d.state == "connecting"
      if isConn then
        if not wifiConnected or d.device == defaultDev then
          wifiConnected = d
        end
      end
    end
  end

  if ethConnected then
    local label = ethConnected.conn ~= "" and ethConnected.conn or ethConnected.device
    return ethDev, "ethernet", { kind = "ethernet", name = label }
  elseif wifiEnabled or wifiConnected then
    local label = (wifiConnected and wifiConnected.conn) or ""
    return ethDev, "wifi", { kind = "wifi", name = label }
  else
    return ethDev, "none", { kind = "none", name = "" }
  end
end

local function applyAudioOutput(stdout)
  local kv = {}
  for line in string.gmatch(stdout or "", "[^\n]+") do
    local k, v = string.match(line, "^([%w_]+)=(.*)$")
    if k then kv[k] = v end
  end

  local changed = false
  local v, muted = parseVol(kv.vol)
  if v and not isLocked("vol") and not cmdInFlight["vol"] then
    if S.vol ~= v then
      changed = true
    end
    S.vol = v
    S.volApplied = v
  end
  if kv.vol then
    if S.volMuted ~= muted then changed = true end
    S.volMuted = muted
  end

  local m, mmuted = parseVol(kv.mic)
  if m and not isLocked("mic") and not cmdInFlight["mic"] then
    if S.mic ~= m then
      changed = true
    end
    S.mic = m
    S.micApplied = m
  end
  if kv.mic then
    if S.micMuted ~= mmuted then changed = true end
    S.micMuted = mmuted
  end

  if v or m then
    if not S.audioReady then
      changed = true
    end
    S.audioReady = true
  end

  return changed
end

-- ---------- local (non-shell) reads ----------

function M.readLocal()
  local docs = readJsonFiles()
  S.noctaliaSync = readSyncBrightnessSetting(docs)
  readQuickStates(docs)

  local up = noctalia.readFile("/proc/uptime")
  S.uptime = up and formatUptime(tonumber(string.match(up, "^(%d+)")) or 0) or ""

  S.hasBattery = false
  for _, name in ipairs(noctalia.listDir("/sys/class/power_supply") or {}) do
    if string.sub(name, 1, 3) == "BAT" then
      S.hasBattery = true
      break
    end
    local ptype = noctalia.readFile("/sys/class/power_supply/" .. name .. "/type")
    if ptype and noctalia.string.trim(ptype) == "Battery" then
      S.hasBattery = true
      break
    end
  end

  if not isLocked("power") then
    local acpi = noctalia.readFile("/sys/firmware/acpi/platform_profile")
    if acpi then
      local p = noctalia.string.trim(acpi)
      if p == "low-power" then p = "power-saver" end
      if p == "power-saver" or p == "balanced" or p == "performance" then
        S.powerProfile = p
      end
    end
  end
end

-- ---------- on-demand & periodic polling ----------

function M.refreshAudio(done)
  if readingAudio then
    if done then done() end
    return
  end
  readingAudio = true
  noctalia.runAsync(AUDIO_POLL, function(res)
    readingAudio = false
    if applyAudioOutput(res and res.stdout or "") then
      M.onChange(false)
    end
    if done then done() end
  end)
end

function M.refreshBrightness(readAll, done, ignoreBusy)
  if #S.monitors == 0 or readingBrightness then
    if done then done() end
    return
  end

  readingBrightness = true
  local targets = S.monitors
  if not readAll and S.syncBrightness then
    targets = { S.monitors[1] }
  end

  -- Run sequentially so ddcutil never contends for /dev/i2c-* locks.
  local lines = {}
  for _, m in ipairs(targets) do
    if m.backlight then
      table.insert(lines, string.format(
        'echo "bri_%s=$(cat /sys/class/backlight/%s/brightness 2>/dev/null) $(cat /sys/class/backlight/%s/max_brightness 2>/dev/null)"',
        m.bus, m.backlight, m.backlight
      ))
    else
      table.insert(lines, string.format(
        'echo "bri_%s=$(ddcutil --bus=%s getvcp 10 --brief 2>/dev/null)"',
        m.bus, m.bus
      ))
    end
  end

  noctalia.runAsync(table.concat(lines, "\n"), function(res)
    readingBrightness = false
    if not ignoreBusy and isAnyBrightnessBusy() then
      if done then done() end
      return
    end

    local kv = {}
    for line in string.gmatch((res and res.stdout) or "", "[^\n]+") do
      local k, v = string.match(line, "^([%w_%-]+)=(.*)$")
      if k then kv[k] = v end
    end

    local changed = false
    local syncedPct, syncedMax

    for _, mon in ipairs(targets) do
      local key = "bri_" .. mon.bus
      local raw = kv[key]
      if raw then
        local pct, max = parseVcp10(raw)
        if pct then
          if mon.value ~= pct or not mon.ready then
            changed = true
          end
          mon.value = pct
          mon.targetPct = pct
          mon.lastSentPct = pct
          mon.noctaliaPct = pct
          mon.max = max
          mon.ready = true
          syncedPct = syncedPct or pct
          syncedMax = syncedMax or max
        end
      end
    end

    if S.syncBrightness and syncedPct then
      S.syncTargetPct = syncedPct
      S.syncLastSentPct = syncedPct
      S.syncNoctaliaPct = syncedPct
      for _, mon in ipairs(S.monitors) do
        if mon.value ~= syncedPct or not mon.ready then
          changed = true
        end
        mon.value = syncedPct
        mon.targetPct = syncedPct
        mon.lastSentPct = syncedPct
        mon.noctaliaPct = syncedPct
        mon.max = syncedMax or mon.max or 100
        mon.ready = true
      end
    elseif #S.monitors > 0 then
      -- Fallback: if a detected monitor refuses VCP 10 reads, still allow slider writes.
      for _, mon in ipairs(S.monitors) do
        if not mon.ready then
          mon.ready = true
          mon.targetPct = mon.value
          mon.noctaliaPct = mon.value
          changed = true
        end
      end
      if S.syncBrightness and S.syncTargetPct == nil then
        local fallback = S.monitors[1].value
        S.syncTargetPct = fallback
        S.syncNoctaliaPct = fallback
      end
    end

    if changed then
      M.onChange(false)
    end
    if done then done() end
  end)
end

function M.detectMonitors(done)
  if detectingMonitors then
    if done then done() end
    return
  end
  detectingMonitors = true
  noctalia.runAsync({ "ddcutil", "detect", "--brief" }, function(res)
    detectingMonitors = false
    local stdout = (res and res.stdout) or ""
    local parsed = parseMonitors(stdout)

    if #parsed > 0 then
      S.monitors = parsed
      S.monitorsScanned = true
    else
      local bl = scanBacklights()
      if #bl > 0 then
        S.monitors = bl
        S.monitorsScanned = true
        local pct = bl[1].value
        S.syncTargetPct = pct
        S.syncLastSentPct = pct
        S.syncNoctaliaPct = pct
      elseif res and res.exitCode == 0 then
        S.monitors = {}
        S.monitorsScanned = true
      end
    end

    M.onChange(false)
    if done then done() end
  end)
end

function M.refreshFast()
  M.readLocal()
  noctalia.runAsync(FAST_POLL, function(res)
    local stdout = (res and res.stdout) or ""
    applyAudioOutput(stdout)

    local kv, devs = {}, {}
    for line in string.gmatch(stdout, "[^\n]+") do
      local k, v = string.match(line, "^([%w_]+)=(.*)$")
      if k == "dev" then
        local device, kind, state, conn = string.match(v, "^([^:]*):([^:]*):([^:]*):(.*)$")
        if device then
          table.insert(devs, {
            device = device,
            kind = kind,
            state = state,
            conn = string.gsub(conn, "\\:", ":"),
          })
        end
      elseif k then
        kv[k] = v
      end
    end

    local wifiEnabled = kv.wifi == "enabled"
    local ethDev, netMode, netObj = analyzeNet(devs, string.match(kv.dflt or "", "dev (%S+)"), wifiEnabled)
    S.ethDev = ethDev

    if not isLocked("net") then
      S.wifi = wifiEnabled
      S.netMode = netMode
      S.net = netObj
    end

    if not isLocked("bt") then
      S.bt = kv.bt == "yes"
    end
    S.btc = tonumber(kv.btc) or 0

    if not isLocked("power") and kv.pwr and kv.pwr ~= "" then
      local p = noctalia.string.trim(kv.pwr)
      if p == "power-saver" or p == "balanced" or p == "performance" then
        S.powerProfile = p
      end
    end

    M.onChange(false)
  end)
end

-- Called every 250ms by panel.luau while open
function M.tick(fastIntervalMs)
  if not panelActive then return end
  local now = noctalia.nowMs()

  -- 1. Live audio check every 250ms (catches external volume/mute keybinds)
  if not isLocked("vol") and not isLocked("mic") and not cmdInFlight["vol"] and not cmdInFlight["mic"] then
    M.refreshAudio()
  end

  -- 2. Network, bluetooth, power profile, uptime on configured interval
  if now - lastFastPollMs >= (fastIntervalMs or 2000) then
    lastFastPollMs = now
    M.refreshFast()
  end

  -- 3. External brightness keybind check every 1000ms when idle
  if #S.monitors > 0 and not isAnyBrightnessBusy() and now - lastBriPollMs >= 1000 then
    lastBriPollMs = now
    M.refreshBrightness(false)
  end
end

-- ---------- lifecycle ----------

function M.open()
  panelActive = true
  local now = noctalia.nowMs()
  lastFastPollMs = now
  lastBriPollMs = now

  M.refreshFast()

  if not S.monitorsScanned then
    M.detectMonitors(function()
      if panelActive then
        M.refreshBrightness(true)
      end
    end)
  else
    M.refreshBrightness(true)
  end
end

function M.close()
  panelActive = false
  M.refreshFast()
  if S.monitorsScanned and #S.monitors > 0 then
    M.refreshBrightness(true)
  end
end

-- ---------- actions ----------

-- Cycles: Wired (if available) -> Wi-Fi -> Disabled
function M.cycleNetwork()
  M.cooldown["net"] = noctalia.nowMs() + 2500

  if S.netMode == "ethernet" then
    S.netMode = "wifi"
    S.wifi = true
    S.net = { kind = "wifi", name = "" }
    M.onChange(true)

    local cmd = "nmcli radio wifi on"
    if S.ethDev then
      cmd = cmd .. string.format("; nmcli dev disconnect %q 2>/dev/null", S.ethDev)
    end
    noctalia.runAsync(cmd, function()
      M.refreshFast()
    end)
  elseif S.netMode == "wifi" then
    S.netMode = "none"
    S.wifi = false
    S.net = { kind = "none", name = "" }
    M.onChange(true)

    local cmd = "nmcli radio wifi off"
    if S.ethDev then
      cmd = cmd .. string.format("; nmcli dev disconnect %q 2>/dev/null", S.ethDev)
    end
    noctalia.runAsync(cmd, function()
      M.refreshFast()
    end)
  else
    if S.ethDev then
      S.netMode = "ethernet"
      S.wifi = false
      S.net = { kind = "ethernet", name = S.ethDev }
      M.onChange(true)

      local cmd = string.format("nmcli radio wifi off; nmcli dev connect %q 2>/dev/null", S.ethDev)
      noctalia.runAsync(cmd, function()
        M.refreshFast()
      end)
    else
      S.netMode = "wifi"
      S.wifi = true
      S.net = { kind = "wifi", name = "" }
      M.onChange(true)

      noctalia.runAsync({ "nmcli", "radio", "wifi", "on" }, function()
        M.refreshFast()
      end)
    end
  end
end

-- Cycles theme-mode: dark -> light -> auto -> dark
function M.cycleThemeMode()
  local nextMode = THEME_CYCLE[S.themeMode] or "dark"
  S.themeMode = nextMode
  M.cooldown["themeMode"] = noctalia.nowMs() + 1500
  M.onChange(true)
  noctalia.runAsync({ "noctalia", "msg", "theme-mode-set", nextMode }, function()
    M.readLocal()
    M.onChange(false)
  end)
end

-- profile: "power-saver" | "balanced" | "performance"
function M.setPowerProfile(profile)
  S.powerProfile = profile
  M.cooldown["power"] = noctalia.nowMs() + 2000
  M.onChange(true)
  noctalia.runAsync({ "noctalia", "msg", "power-set", profile }, function()
    M.refreshFast()
  end)
end

-- what: bt | vol | mic | nightLight | caffeine | dnd
function M.toggle(what)
  if what == "bt" then
    S.bt = not S.bt
    M.cooldown["bt"] = noctalia.nowMs() + 2000
    M.onChange(true)
    noctalia.runAsync({ "bluetoothctl", "power", S.bt and "on" or "off" }, function()
      M.refreshFast()
    end)
    return
  end

  if what == "vol" or what == "mic" then
    S[what .. "Muted"] = not S[what .. "Muted"]
    M.onChange(true)
    noctalia.runAsync({ "wpctl", "set-mute", TARGET[what], "toggle" }, function()
      M.refreshAudio()
    end)
    return
  end

  local argv = QUICK_CLI[what]
  if argv then
    S[what] = not S[what]
    M.cooldown[what] = noctalia.nowMs() + 1500
    M.onChange(true)
    noctalia.runAsync(argv, function()
      M.readLocal()
      M.onChange(false)
    end)
  end
end

local function applyAudioDelta(what, onDone)
  local appliedKey = what .. "Applied"
  runCoalesced(what, function()
    local delta = S[what] - S[appliedKey]
    if delta == 0 then return nil end
    S[appliedKey] = S[what]
    local subcmd = delta > 0 and CLI_STEP[what].up or CLI_STEP[what].down
    return { "noctalia", "msg", subcmd, tostring(math.abs(delta)) }
  end, onDone)
end

local function buildHardwareCmd(m, pct)
  local max = m.max or 100
  local raw = math.floor((pct / 100) * max + 0.5)
  if m.backlight then
    return string.format("echo %d > /sys/class/backlight/%s/brightness 2>/dev/null", raw, m.backlight)
  end
  return string.format("ddcutil --bus=%s --noverify setvcp 10 %d 2>/dev/null", m.bus, raw)
end

-- Direct hardware write while dragging (sequential to avoid /dev/i2c-* lock contention)
local function applyBrightnessHardware(mon, onDone)
  if S.syncBrightness then
    runCoalesced("bri_all", function()
      local pct = S.syncTargetPct
      if pct == nil or pct == S.syncLastSentPct then
        return nil
      end
      S.syncLastSentPct = pct

      local cmds = {}
      for _, m in ipairs(S.monitors) do
        m.lastSentPct = pct
        table.insert(cmds, buildHardwareCmd(m, pct))
      end
      return table.concat(cmds, "\n")
    end, onDone)
  else
    runCoalesced("bri_" .. mon.bus, function()
      local pct = mon.targetPct
      if pct == nil or pct == mon.lastSentPct then
        return nil
      end
      mon.lastSentPct = pct
      if mon.backlight then
        return buildHardwareCmd(mon, pct)
      end
      local max = mon.max or 100
      local raw = math.floor((pct / 100) * max + 0.5)
      return {
        "ddcutil",
        "--bus=" .. mon.bus,
        "--noverify",
        "setvcp",
        "10",
        tostring(raw),
      }
    end, onDone)
  end
end

-- Notifies Noctalia's BrightnessService so official widgets stay in sync.
local function syncNoctaliaBrightness(mon)
  local nkey = S.syncBrightness and "noctalia_bri_all" or ("noctalia_bri_" .. mon.bus)

  runCoalesced(nkey, function()
    local targetPct = S.syncBrightness and S.syncTargetPct or mon.targetPct
    local currentNoctalia = S.syncBrightness and S.syncNoctaliaPct or mon.noctaliaPct

    if targetPct == nil or currentNoctalia == nil then
      return nil
    end

    local delta = targetPct - currentNoctalia
    if delta == 0 then
      return nil
    end

    if S.syncBrightness then
      S.syncNoctaliaPct = targetPct
      for _, m in ipairs(S.monitors) do
        m.noctaliaPct = targetPct
      end
    else
      mon.noctaliaPct = targetPct
    end

    local subcmd = delta > 0 and "brightness-up" or "brightness-down"
    local step = tostring(math.abs(delta))

    local targetArg = "all"
    if S.syncBrightness then
      local first = S.monitors[1]
      if S.noctaliaSync and first and first.drm and first.drm ~= "" then
        targetArg = first.drm
      end
    elseif mon.drm and mon.drm ~= "" then
      targetArg = mon.drm
    end

    return { "noctalia", "msg", subcmd, targetArg, step }
  end)
end

-- Apply at most every `ms` while dragging; `force` bypasses the throttle.
local function throttled(name, ms, fn, force)
  local now = noctalia.nowMs()
  if force or now - (lastSet[name] or 0) >= ms then
    lastSet[name] = now
    fn()
  end
end

-- Click on brightness tile sets configured preset (default 0.05 = 5%), respecting sync_all_monitors.
function M.applyBrightnessPreset(mon)
  if not mon or not mon.ready then return end

  local rawPreset = tonumber(noctalia.getConfig("brightness_preset"))
  if rawPreset == nil then rawPreset = 0.05 end

  local pct
  if rawPreset <= 1 then
    pct = math.floor(rawPreset * 100 + 0.5)
  else
    pct = math.floor(rawPreset + 0.5)
  end
  pct = math.max(0, math.min(100, pct))

  local key = S.syncBrightness and "bri_all" or ("bri_" .. mon.bus)
  briSyncGen[key] = (briSyncGen[key] or 0) + 1
  M.dragging[key] = false
  M.cooldown[key] = noctalia.nowMs() + 1500

  if S.syncBrightness then
    S.syncTargetPct = pct
    for _, m in ipairs(S.monitors) do
      if m.ready then
        m.value = pct
        m.targetPct = pct
      end
    end
  else
    mon.value = pct
    mon.targetPct = pct
  end

  M.onChange(true)
  applyBrightnessHardware(mon)
  syncNoctaliaBrightness(mon)
end

-- Returns (onChange, onDragEnd) for audio sliders (vol | mic).
function M.slider(what)
  local function onChange(v)
    if not S.audioReady then return end
    v = math.floor((tonumber(v) or 0) + 0.5)
    if v == S[what] then return end

    S[what] = v
    M.dragging[what] = true
    M.dragSince[what] = noctalia.nowMs()
    M.cooldown[what] = noctalia.nowMs() + 600
    M.onChange(true)
    throttled(what, 45, function()
      applyAudioDelta(what)
    end)
  end

  local function onEnd()
    if not S.audioReady then return end
    M.dragging[what] = false
    M.cooldown[what] = noctalia.nowMs() + 600
    throttled(what, 45, function()
      applyAudioDelta(what, function()
        M.refreshAudio()
      end)
    end, true)
  end

  return onChange, onEnd
end

-- Returns (onChange, onDragEnd) for a specific DDC monitor.
function M.monitorSlider(mon)
  local key = S.syncBrightness and "bri_all" or ("bri_" .. mon.bus)

  local function setTarget(v)
    if S.syncBrightness then
      S.syncTargetPct = v
      for _, m in ipairs(S.monitors) do
        if m.ready then
          m.value = v
          m.targetPct = v
        end
      end
    else
      mon.value = v
      mon.targetPct = v
    end
  end

  local function scheduleNoctaliaSync()
    briSyncGen[key] = (briSyncGen[key] or 0) + 1
    local gen = briSyncGen[key]
    noctalia.runAsync("sleep 0.18", function()
      if briSyncGen[key] == gen then
        M.dragging[key] = false
        syncNoctaliaBrightness(mon)
      end
    end)
  end

  local function onChange(v)
    if not mon.ready then return end
    v = math.floor((tonumber(v) or 0) + 0.5)
    if v == mon.value then return end

    setTarget(v)
    M.dragging[key] = true
    M.dragSince[key] = noctalia.nowMs()
    M.cooldown[key] = noctalia.nowMs() + 1500
    M.onChange(true)

    throttled(key, 60, function()
      applyBrightnessHardware(mon)
    end)

    scheduleNoctaliaSync()
  end

  local function onEnd()
    if not mon.ready then return end
    briSyncGen[key] = (briSyncGen[key] or 0) + 1
    M.dragging[key] = false
    M.cooldown[key] = noctalia.nowMs() + 1500

    throttled(key, 60, function()
      applyBrightnessHardware(mon)
    end, true)

    syncNoctaliaBrightness(mon)
  end

  return onChange, onEnd
end

return M
