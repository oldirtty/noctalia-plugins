--!nonstrict
local common = require("./lib/common.luau")

local label = noctalia.getConfig("label")
local color = common.labelColor()
local value = "..."

local function parse(out)
  return out:match("Powered:%s*yes") and "on" or "off"
end

local function draw()
  barWidget.render(common.tree(barWidget.isVertical(), label, color, value))
end

function update()
  common.poll("bluetoothctl show", parse, function(v)
    value = v
    draw()
  end)
end

function onRightClick()
  local toggle = 'if bluetoothctl show | grep -q "Powered: yes"; then bluetoothctl power off; else bluetoothctl power on; fi'
  noctalia.runAsync({ "sh", "-c", toggle }, update)
end

noctalia.setUpdateInterval(2000)
draw()
update()
