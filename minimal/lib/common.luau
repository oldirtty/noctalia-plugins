--!nonstrict
local M = {}
local width = {}

-- retorna nil por padrão para usar a "Widget color" nativa da barra;
-- só aplica cor customizada se o override estiver ativado no widget
function M.textColor()
  if noctalia.getConfig("use_custom_color") then
    return noctalia.getConfig("custom_color")
  end
  return nil
end

function M.setWidth(min, max)
  width.min = min > 0 and min or nil
  width.max = max > 0 and max or nil
end

function M.tree(vertical, color, value)
  local container = vertical and ui.column or ui.row

  return container({ gap = 4, align = "center", minWidth = width.min }, {
    ui.label({
      text = value,
      color = color,
      maxWidth = width.max,
      maxLines = width.max and 1 or nil,
    }),
  })
end

function M.poll(cmd, parse, set)
  noctalia.runAsync(cmd, function(result)
    set(parse(result.stdout or ""))
  end)
end

return M
