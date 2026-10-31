--!nonstrict
local M = {}
local width = {}

-- widget override if enabled, otherwise the plugin-wide default
function M.labelColor()
  if noctalia.getConfig("use_custom_color") then
    return noctalia.getConfig("custom_color")
  end
  return noctalia.getConfig("label_color")
end

-- px limits used by tree(): min on the whole row, max on the value text
function M.setWidth(min, max)
  width.min = min > 0 and min or nil
  width.max = max > 0 and max or nil
end

-- "label: value", label colored, value in the widget's default color
function M.tree(vertical, label, color, value)
  local container = vertical and ui.column or ui.row

  return container({ gap = 4, align = "center", minWidth = width.min }, {
    label ~= "" and
      ui.label({ text = label..":", color = color }) or
      "",
    ui.label({ text = value, maxWidth = width.max, maxLines = width.max and 1 or nil }),
  })
end

-- runs cmd, parses stdout and hands the result to set()
function M.poll(cmd, parse, set)
  noctalia.runAsync(cmd, function(result)
    set(parse(result.stdout or ""))
  end)
end

-- description of a wpctl target (e.g. "@DEFAULT_AUDIO_SINK@")
function M.deviceName(target, set)
  noctalia.runAsync("wpctl inspect " .. target .. " | grep node.description", function(result)
    set((result.stdout or ""):match('node%.description%s*=%s*"([^"]*)"') or "?")
  end)
end

-- last loaded EasyEffects preset for "output" or "input"; nil when there is none
-- (pgrep first: the CLI would otherwise start EasyEffects when it is not running;
-- the preset is always the very last line, so an empty last line means no preset)
function M.effectsPreset(kind, set)
  noctalia.runAsync("pgrep -x easyeffects >/dev/null && easyeffects -a " .. kind .. " 2>/dev/null", function(result)
    local out = (result.stdout or ""):gsub("\n$", "")
    local name = noctalia.string.trim(out:match("([^\n]*)$"))
    set(name ~= "" and name or nil)
  end)
end

return M
