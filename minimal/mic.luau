--!nonstrict
local common = require("./lib/common.luau")

local label = noctalia.getConfig("label")
local color = common.labelColor()
local value = "..."
local device = "?"
local effects = nil
local tick = 0

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

local function tooltip()
  local rows = { { "Mic", value }, { "Device", device } }
  if effects then
    rows[#rows + 1] = { "Effects", effects }
  end
  barWidget.setTooltip(rows)
end

function update()
  -- device and preset rarely change: refresh them every 8th tick, not every 250 ms
  if tick % 8 == 0 then
    common.deviceName("@DEFAULT_AUDIO_SOURCE@", function(d)
      device = d
      tooltip()
    end)
    common.effectsPreset("input", function(e)
      effects = e
      tooltip()
    end)
  end
  tick = tick + 1
  common.poll("wpctl get-volume @DEFAULT_AUDIO_SOURCE@", parse, function(v)
    value = v
    draw()
    tooltip()
  end)
end

function onRightClick()
  noctalia.runAsync({ "wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle" }, update)
end

noctalia.setUpdateInterval(250)
draw()
update()
