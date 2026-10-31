--!nonstrict
local common = require("./lib/common.luau")

local label = noctalia.getConfig("label")
local color = common.labelColor()
local value = "..."

local function capitalize(s)
  return s:sub(1, 1):upper() .. s:sub(2)
end

-- stays hidden until Umbriel reports a focused workspace
barWidget.setVisible(false)

noctalia.runStream("umbriel subscribe workspaces", function(line)
  local msg = noctalia.json.decode(line)
  if type(msg) ~= "table" or type(msg.data) ~= "table" then
    return
  end
  for _, ws in ipairs(msg.data) do
    if ws.focused and ws.layout then
      barWidget.render(common.tree(barWidget.isVertical(), label, color, capitalize(ws.layout)))
      barWidget.setVisible(true)
      return
    end
  end
end)
