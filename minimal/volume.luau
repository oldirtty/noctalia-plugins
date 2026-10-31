--!nonstrict
local common = require("./lib/common.luau")

local label = noctalia.getConfig("label")
local color = common.labelColor()
local value = "..."

local function parse(out)
  if out:find("MUTED", 1, true) then
    return "muted"
  end
  local v = out:match("Volume:%s*([%d%.]+)")
  return v and string.format("%d%%", math.floor(tonumber(v) * 100 + 0.5)) or "?"
end

local function draw()
  barWidget.render(common.tree(barWidget.isVertical(), label, color, value))
end

function update()
  common.poll("wpctl get-volume @DEFAULT_AUDIO_SINK@", parse, function(v)
    value = v
    draw()
  end)
end

function onRightClick()
  noctalia.runAsync({ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" }, update)
end

noctalia.setUpdateInterval(2000)
draw()
update()
