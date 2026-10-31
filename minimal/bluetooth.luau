--!nonstrict
local common = require("./lib/common.luau")

local label = noctalia.getConfig("label")
local color = common.labelColor()
local value = "..."

-- before "---": `bluetoothctl show`; after: Name/Battery of each connected device
local function parse(out)
  local rows = {}
  local devices = false
  for line in out:gmatch("[^\n]+") do
    if line == "---" then
      devices = true
    elseif devices then
      local name = line:match("Name:%s*(.+)$")
      local pct = line:match("Battery Percentage:%s*%S+%s*%((%d+)%)")
      if name then
        rows[#rows + 1] = { name, "connected" }
      elseif pct and #rows > 0 then
        rows[#rows][2] = pct .. "%"
      end
    end
  end
  return out:match("Powered:%s*yes") and "on" or "off", rows
end

local function draw()
  barWidget.render(common.tree(barWidget.isVertical(), label, color, value))
end

function update()
  local cmd = "bluetoothctl show; echo ---; for m in $(bluetoothctl devices Connected | cut -d' ' -f2); do bluetoothctl info $m | grep -E 'Name:|Battery Percentage:'; done"
  common.poll(cmd, parse, function(v, rows)
    value = v
    draw()
    if #rows > 0 then
      barWidget.setTooltip(rows)
    else
      barWidget.clearTooltip()
    end
  end)
end

function onRightClick()
  local toggle = 'if bluetoothctl show | grep -q "Powered: yes"; then bluetoothctl power off; else bluetoothctl power on; fi'
  noctalia.runAsync({ "sh", "-c", toggle }, update)
end

noctalia.setUpdateInterval(2000)
draw()
update()
