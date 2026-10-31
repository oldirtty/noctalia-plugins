--!nonstrict
local common = require("./lib/common.luau")

local label = noctalia.getConfig("label")
local wiredLabel = noctalia.getConfig("wired_label")
local color = common.labelColor()
local shownLabel = label
local value = "..."

local function speed(bytesPerSec)
  if bytesPerSec >= 1000000 then
    return string.format("%.1f MB/s", bytesPerSec / 1000000)
  end
  return string.format("%.1f kB/s", bytesPerSec / 1000)
end

local function tooltip(network, dev, ip)
  local rows = {
    { "Network", network },
    { "Interface", dev or "-" },
    { "IP", ip or "-" },
  }
  local stats = noctalia.systemStats()
  local ifaces = stats and stats.net and stats.net.interfaces
  local iface = ifaces and dev and ifaces[dev]
  if iface then
    rows[#rows + 1] = { "Download", speed(iface.rxBytesPerSec or 0) }
    rows[#rows + 1] = { "Upload", speed(iface.txBytesPerSec or 0) }
  end
  return rows
end

-- wired wins over wifi; the SSID comes from the active wifi line
local function parse(out)
  local wired, wifiDev, ssid
  local ips = {}
  for line in out:gmatch("[^\n]+") do
    wired = wired or line:match("^([^:]+):ethernet:connected$")
    wifiDev = wifiDev or line:match("^([^:]+):wifi:connected$")
    local s = line:match("^yes:(.*)$")
    if s and not ssid then
      ssid = s:gsub("\\:", ":")
    end
    local iface, ip = line:match("^%d+:%s+(%S+)%s+inet%s+([%d%.]+)")
    if iface then
      ips[iface] = ip
    end
  end
  if wired then
    return wiredLabel, "wired", tooltip("Wired", wired, ips[wired])
  elseif ssid then
    return label, ssid, tooltip(ssid, wifiDev, wifiDev and ips[wifiDev])
  end
  return label, "off", nil
end

local function draw()
  barWidget.render(common.tree(barWidget.isVertical(), shownLabel, color, value))
end

function update()
  local cmd = "nmcli -t -f device,type,state dev; nmcli -t -f active,ssid dev wifi; ip -4 -o addr show scope global"
  common.poll(cmd, parse, function(l, v, rows)
    shownLabel = l
    value = v
    draw()
    if rows then
      barWidget.setTooltip(rows)
    else
      barWidget.clearTooltip()
    end
  end)
end

function onRightClick()
  local toggle = 'if [ "$(nmcli radio wifi)" = enabled ]; then nmcli radio wifi off; else nmcli radio wifi on; fi'
  noctalia.runAsync({ "sh", "-c", toggle }, update)
end

noctalia.setUpdateInterval(2000)
draw()
update()
