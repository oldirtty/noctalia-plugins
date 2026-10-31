--!nonstrict
local common = require("./lib/common.luau")

local label = noctalia.getConfig("label")
local color = common.labelColor()
local value = "..."

local function parse(out)
  local n = out:match("%d+")
  return n and (n .. "%") or nil
end

local function draw()
  barWidget.render(common.tree(barWidget.isVertical(), label, color, value))
end

function update()
  common.poll("cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -n1", parse, function(v)
    barWidget.setVisible(v ~= nil)
    if v ~= nil then
      value = v
      draw()
    end
  end)
end

noctalia.setUpdateInterval(2000)
barWidget.setVisible(false)
draw()
update()
