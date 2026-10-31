--!nonstrict
local M = {}

-- widget override if enabled, otherwise the plugin-wide default
function M.labelColor()
  if noctalia.getConfig("use_custom_color") then
    return noctalia.getConfig("custom_color")
  end
  return noctalia.getConfig("label_color")
end

-- "label: value", label colored, value in the widget's default color
function M.tree(vertical, label, color, value)
  local container = vertical and ui.column or ui.row
  return container({ gap = 4, align = "center" }, {
    ui.label({ text = label .. ":", color = color }),
    ui.label({ text = value }),
  })
end

-- runs cmd, parses stdout and hands the result to set()
function M.poll(cmd, parse, set)
  noctalia.runAsync(cmd, function(result)
    set(parse(result.stdout or ""))
  end)
end

return M
