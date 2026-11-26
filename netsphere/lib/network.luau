--!nonstrict

-- Network state and actions for Netsphere. No UI in here.
-- State comes from one NetworkManager poll that runs (a) immediately on every
-- `nmcli monitor` event, (b) as a 5 s fallback, (c) after every action.
-- Throughput comes from the shell's system monitor, no process involved.

local M = {}

local FALLBACK_MS = 5000

local POLL = [[
echo "wifi=$(nmcli radio wifi 2>/dev/null)"
echo "dflt=$(ip route show default 2>/dev/null | head -1)"
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev 2>/dev/null | sed 's/^/dev=/'
nmcli -t -f ACTIVE,SIGNAL,SSID dev wifi list --rescan no 2>/dev/null | grep '^yes:' | head -1 | sed 's/^/sig=/'
ip -4 -o addr show 2>/dev/null | awk '{print "ip=" $2 " " $4}'
]]

local S = {
  mode = "off",        -- wired | wifi | off
  connected = false,   -- the active mode actually has a link
  wiredDev = nil,      -- usable ethernet device name, if any
  wifiDev = nil,       -- wifi device name, if any
  iface = nil,         -- interface of the active mode
  ssid = "",
  signal = nil,        -- 0-100
  ip = nil,
  rx = 0,
  tx = 0,
}

M.state = S
M.onChange = function() end

local inflight = false
local again = false
local lastPoll = 0

-- ---------- helpers ----------

local function unescape(s)
  return (string.gsub(s, "\\:", ":"))
end

local function isConnected(d)
  return d ~= nil and string.sub(d.state, 1, 9) == "connected"
end

local function quote(s)
  return "'" .. (string.gsub(s, "'", "'\\''")) .. "'"
end

function M.formatRate(bytes)
  local units = { "B/s", "kB/s", "MB/s", "GB/s" }
  local i = 1
  while bytes >= 1000 and i < #units do
    bytes = bytes / 1000
    i = i + 1
  end
  return string.format(i == 1 and "%.0f %s" or "%.1f %s", bytes, units[i])
end

-- ---------- polling ----------

local function apply(out)
  local kv, devs, ips = {}, {}, {}
  for line in string.gmatch(out or "", "[^\n]+") do
    local k, v = string.match(line, "^(%w+)=(.*)$")
    if k == "dev" then
      local device, kind, state, conn = string.match(v, "^([^:]*):([^:]*):([^:]*):(.*)$")
      if device then
        table.insert(devs, { device = device, kind = kind, state = state, conn = unescape(conn) })
      end
    elseif k == "ip" then
      local name, addr = string.match(v, "^(%S+) ([%d%.]+)")
      if name and not ips[name] then ips[name] = addr end
    elseif k then
      kv[k] = v
    end
  end

  -- Prefer a connected ethernet device; skip ones with no cable/unmanaged.
  local wired, wifi
  for _, d in ipairs(devs) do
    if d.kind == "ethernet" then
      local usable = d.state ~= "unavailable" and d.state ~= "unmanaged"
      if usable and (wired == nil or (isConnected(d) and not isConnected(wired))) then
        wired = d
      end
    elseif d.kind == "wifi" and wifi == nil then
      wifi = d
    end
  end

  local wifiOn = kv.wifi == "enabled" and wifi ~= nil
  local dflt = string.match(kv.dflt or "", "dev (%S+)")

  local mode
  if wifiOn and isConnected(wifi) and wifi.device == dflt then
    mode = "wifi"
  elseif isConnected(wired) then
    mode = "wired"
  elseif wifiOn then
    mode = "wifi"
  else
    mode = "off"
  end

  S.mode = mode
  S.wiredDev = wired and wired.device or nil
  S.wifiDev = wifi and wifi.device or nil
  S.ssid = ""
  S.signal = nil

  if mode == "wired" then
    S.connected = true
    S.iface = wired.device
  elseif mode == "wifi" then
    S.connected = isConnected(wifi)
    S.iface = wifi.device
    local signal, ssid = string.match(kv.sig or "", "^yes:(%d+):(.*)$")
    if signal then
      S.signal = tonumber(signal)
      S.ssid = unescape(ssid)
    elseif S.connected then
      S.ssid = wifi.conn
    end
  else
    S.connected = false
    S.iface = nil
  end

  S.ip = S.iface and ips[S.iface] or nil
end

-- Runs now; a request that arrives mid-poll schedules exactly one more run.
function M.refresh()
  if inflight then
    again = true
    return
  end
  inflight = true
  lastPoll = noctalia.nowMs()
  noctalia.runAsync(POLL, function(res)
    inflight = false
    apply(res.stdout)
    M.updateRates()
    M.onChange()
    if again then
      again = false
      M.refresh()
    end
  end)
end

function M.updateRates()
  S.rx, S.tx = 0, 0
  if not S.iface then return end
  local stats = noctalia.systemStats()
  if not (stats and stats.net) then return end
  local i = stats.net.interfaces and stats.net.interfaces[S.iface]
  if i then
    S.rx = i.rxBytesPerSec or 0
    S.tx = i.txBytesPerSec or 0
  else
    S.rx = stats.net.rxBytesPerSec or 0
    S.tx = stats.net.txBytesPerSec or 0
  end
end

-- Call from update(): rates every tick, state fallback poll every 5 s.
function M.tick()
  M.updateRates()
  if noctalia.nowMs() - lastPoll >= FALLBACK_MS then
    M.refresh()
  end
end

function M.start()
  noctalia.runStream("nmcli monitor", function()
    M.refresh()
  end)
  M.refresh()
end

-- ---------- actions ----------

-- mode: wired | wifi | off. Modes are exclusive: switching tears the others down.
function M.setMode(mode)
  local cmds = {}
  if mode == "wired" then
    table.insert(cmds, "nmcli radio wifi off")
    table.insert(cmds, "nmcli dev connect " .. quote(S.wiredDev))
  else
    table.insert(cmds, "nmcli radio wifi " .. (mode == "wifi" and "on" or "off"))
    if S.wiredDev then
      table.insert(cmds, "nmcli dev disconnect " .. quote(S.wiredDev))
    end
  end

  -- Optimistic: show the target mode until the next poll confirms it.
  S.mode = mode
  S.connected = false
  S.iface = nil
  S.ssid = ""
  S.signal = nil
  M.onChange()

  noctalia.runAsync(table.concat(cmds, "; "), function()
    M.refresh()
  end)
end

-- Wired (if a usable device exists) -> Wi-Fi (if a device exists) -> Off -> ...
function M.cycle()
  local order = {}
  if S.wiredDev then table.insert(order, "wired") end
  if S.wifiDev then table.insert(order, "wifi") end
  table.insert(order, "off")

  local index = 1
  for i, mode in ipairs(order) do
    if mode == S.mode then index = i end
  end
  M.setMode(order[index % #order + 1])
end

return M
