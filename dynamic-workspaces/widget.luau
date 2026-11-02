--!nonstrict

local TRANSPARENT = "#00000000"

local workspaces = {}
local output = nil
barWidget.setVisible(true)

local function resolveOutput()
  if output == nil then
    output = barWidget.outputName()
    noctalia.log("bar output: " .. tostring(output))
  end
  return output
end

local WIDGET_TYPE = "oldirtty/workspaces-reworked:workspaces"
local FALLBACK_HEIGHT = 34
local cachedHeight = nil
local cachedContentScale = nil

-- name of this plugin's widget instance listed in one of the bar's lanes, if any
local function laneHas(bar, names)
  for _, lane in ipairs({ "start", "center", "end" }) do
    for _, name in ipairs(bar[lane] or {}) do
      if names[name] then
        return name
      end
    end
  end
  return nil
end

local function monitorOverride(bar, current)
  local description = nil
  for _, o in ipairs(noctalia.outputs()) do
    if o.name == current then
      description = o.description
    end
  end
  for key, m in pairs(bar.monitor or {}) do
    local match = m.match or key
    if match == current or (description and string.find(description, match, 1, true)) then
      return m
    end
  end
  return nil
end

local function outputScale()
  local current = resolveOutput()
  for _, o in ipairs(noctalia.outputs()) do
    if o.name == current then
      return o.scale or 1
    end
  end
  return 1
end

-- height this widget can use on its bar, in logical px: the bar thickness (per-monitor override
-- included), cut to the capsule size only when this widget actually has a capsule
local function findBarHeight()
  local current = resolveOutput()
  local bars = noctalia.getSetting("bar")
  local widgets = noctalia.getSetting("widget")
  if current == nil or type(bars) ~= "table" or type(widgets) ~= "table" then
    return nil
  end

  local mine = {}
  for name, cfg in pairs(widgets) do
    if type(cfg) == "table" and cfg.type == WIDGET_TYPE then
      mine[name] = true
    end
  end

  for name, bar in pairs(bars) do
    if name ~= "order" and type(bar) == "table" then
      local override = monitorOverride(bar, current) or {}
      local instance = laneHas(override, mine) or laneHas(bar, mine)
      if instance then
        local function pick(key, default)
          if override[key] ~= nil then
            return override[key]
          end
          if bar[key] ~= nil then
            return bar[key]
          end
          return default
        end

        local capsule = widgets[instance].capsule
        if capsule == nil then
          capsule = pick("capsule", false)
        end
        -- ui.* sizes are multiplied by the bar and widget content scale, the bar thickness is not
        local contentScale = pick("scale", 1) * (widgets[instance].scale or 1)
        local thickness = pick("thickness", 34)
        local fraction = capsule and pick("capsule_thickness", 0.76) or 1
        noctalia.log(string.format(
          "bar=%s widget=%s thickness=%s capsule=%s fraction=%s contentScale=%s",
          name, instance, tostring(thickness), tostring(capsule), tostring(fraction), tostring(contentScale)
        ))
        return thickness * fraction, contentScale
      end
    end
  end
  return nil
end

-- returns the height in bar pixels and the content scale that multiplies every ui.* size
local function barHeight()
  if cachedHeight == nil then
    cachedHeight, cachedContentScale = findBarHeight()
    noctalia.log("bar height: " .. tostring(cachedHeight) .. ", output scale: " .. tostring(outputScale()))
  end
  return cachedHeight or FALLBACK_HEIGHT, cachedContentScale or 1
end

-- hex gets an aa suffix, theme tokens get "/alpha" (resolved live against the palette)
local function withAlpha(color, percent)
  local hex = string.match(color, "^(#%x%x%x%x%x%x)")
  if hex then
    return string.format("%s%02x", hex, math.floor(255 * percent / 100 + 0.5))
  end
  local token = string.match(color, "^([^/]+)")
  return string.format("%s/%.2f", token, percent / 100)
end

local function labelFor(ws)
  local labels = noctalia.getConfig("custom_labels")
  return (labels and labels[ws.index]) or tostring(ws.index)
end

local function visibleWorkspaces()
  local current = resolveOutput()
  local items = {}
  for _, ws in ipairs(workspaces) do
    if ws.output == current then
      table.insert(items, ws)
    end
  end
  table.sort(items, function(a, b)
    return a.index < b.index
  end)
  if noctalia.getConfig("hide_last") then
    table.remove(items)
  end
  if noctalia.getConfig("hide_first") then
    table.remove(items, 1)
  end
  return items
end

local function switchTo(ws)
  noctalia.runAsync({ "umbriel", "msg", "workspace-switch:" .. ws.index .. "/" .. ws.output })
end

local render
function render()
  local items = visibleWorkspaces()
  barWidget.setVisible(#items > 0)

  -- floor to whole device pixels (rounding up spills a pixel past the bar), then convert to ui units
  local height, contentScale = barHeight()
  local scale = outputScale()
  local pixels = math.max(1, math.floor(height * noctalia.getConfig("height_percent") / 100 * scale + 0.0001) / scale)
  local thickness = pixels / contentScale
  local sizeProp = barWidget.isVertical() and "width" or "height"

  local chips = {}
  for _, ws in ipairs(items) do
    local state = ws.active and "focused" or (ws.occupied and "occupied" or "empty")
    local fg = noctalia.getConfig(state .. "_foreground")
    local bg = noctalia.getConfig(state .. "_background")
    local paddingH = noctalia.getConfig(ws.active and "active_size" or "inactive_size")
    local alpha = (bg==TRANSPARENT) and 0 or noctalia.getConfig("background_opacity")
    local fill = withAlpha(bg, alpha)
    local text = fg

    local lineColor = TRANSPARENT
    local lineW = 0
    if noctalia.getConfig("show_underline") == true then
      lineColor = noctalia.getConfig(state .. "_underline")
      lineW = noctalia.getConfig("underline_width") / 2 -- setting is in half pixels
    end

    local label = ui.label({
      text = labelFor(ws),
      color = text,
      fontWeight = ws.active and "bold" or nil,
    })

    local children = { label }
    if lineW > 0 then
      -- the line takes space, so a transparent twin on the opposite edge keeps the label centered
      local onTop = noctalia.getConfig("underline_position") == "Top"
      children = {
        ui.box({ key = "line-top", height = lineW, fill = onTop and lineColor or TRANSPARENT }),
        ui.row({ flexGrow = 1, align = "center", justify = "center", paddingH = paddingH }, { label }),
        ui.box({ key = "line-bottom", height = lineW, fill = onTop and TRANSPARENT or lineColor }),
      }
    end

    local props = {
      key = "ws-" .. ws.id .. (ws.active and "-active" or "") .. "-chip",
      fill = fill,
      radius = noctalia.getConfig("radius"),
      paddingH = lineW > 0 and -0.5 or paddingH,
      [sizeProp] = thickness,
      align = lineW > 0 and "stretch" or "center",
      justify = "center",
      onHover = "",
      onClick = function()
        switchTo(ws)
      end,
    }

    -- ui.row and ui.column are distinct function types: calling a union of them is a type error
    local chip
    if lineW > 0 then
      chip = ui.column(props, children)
    else
      chip = ui.row(props, children)
    end
    table.insert(chips, chip)
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({ gap = noctalia.getConfig("gap"), align = "center" }, chips))
end

noctalia.runStream("umbriel subscribe workspaces", function(line)
  local msg = noctalia.json.decode(line)
  if msg and msg.event == "workspaces" then
    workspaces = msg.data
    render()
  end
end)

render()
