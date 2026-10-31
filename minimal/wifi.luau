--!nonstrict
local common = require("./lib/common.luau")

local label = noctalia.getConfig("label")
local color = common.labelColor()
local value = "..."

local function parse(out)
  for line in out:gmatch("[^\n]+") do
    local ssid = line:match("^yes:(.*)$")
    if ssid then
      return (ssid:gsub("\\:", ":"))
    end
  end
  return "off"
end

local function draw()
  barWidget.render(common.tree(barWidget.isVertical(), label, color, value))
end

function update()
  common.poll("nmcli -t -f active,ssid dev wifi", parse, function(v)
    value = v
    draw()
  end)
end

function onRightClick()
  local toggle = 'if [ "$(nmcli radio wifi)" = enabled ]; then nmcli radio wifi off; else nmcli radio wifi on; fi'
  noctalia.runAsync({ "sh", "-c", toggle }, update)
end

noctalia.setUpdateInterval(2000)
draw()
update()
