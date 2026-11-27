--!nonstrict

-- Constants
local TRANSPARENT = "#00000000"
local FONT_RATIO = 0.55 -- Label size relative to available vertical space inside the chip
local FALLBACK_HEIGHT = 34
local DEFAULT_CAPSULE_FRACTION = 0.76
local FRAME_INTERVAL_MS = 16
local IDLE_INTERVAL_MS = 1000
local FULL_HEIGHT_BIAS = 1 -- device pixels added at 100% block height, to cover the row left under the block
local FULL_HEIGHT_EPSILON = 0.999

-- Plugin instances are typed "<author>/<plugin>:workspaces"; extract the folder name
local PLUGIN_NAME = string.match(noctalia.pluginDir() or "", "([^/]+)/*$")

-- Runtime state
local workspaces = {}
local progress = {} -- workspace.id -> animation progress in [0, 1]
local animating = false
local lastTickMs = 0
local loggedUnderline = nil

local cachedOutput = nil
local cachedHeight = nil
local cachedContentScale = nil

barWidget.setVisible(true)

-- Math & color helpers

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function smoothstep(t)
  return t * t * (3 - 2 * t)
end

-- Appends alpha hex byte to #RRGGBB colors or "/alpha" suffix to theme tokens
local function withAlpha(color, alpha)
  local hex = string.match(color, "^(#%x%x%x%x%x%x)")
  if hex then
    return string.format("%s%02x", hex, math.floor(255 * alpha + 0.5))
  end
  local token = string.match(color, "^([^/]+)") or color
  return string.format("%s/%.2f", token, alpha)
end

-- Multiplies the opacity a color already has, so a transparent color stays transparent
local function fade(color, factor)
  local rgb, a = string.match(color, "^(#%x%x%x%x%x%x)(%x?%x?)$")
  if rgb then
    local current = (a ~= "") and (tonumber(a, 16) / 255) or 1
    return string.format("%s%02x", rgb, math.floor(255 * current * factor + 0.5))
  end
  local token, a2 = string.match(color, "^([^/]+)/?(.*)$")
  return string.format("%s/%.2f", token, (tonumber(a2) or 1) * factor)
end

-- Output & bar geometry

local function resolveOutput()
  if cachedOutput == nil then
    cachedOutput = barWidget.outputName()
    noctalia.log("bar output: " .. tostring(cachedOutput))
  end
  return cachedOutput
end

local function currentOutputInfo()
  local current = resolveOutput()
  for _, info in ipairs(noctalia.outputs()) do
    if info.name == current then
      return info
    end
  end
  return nil
end

local function outputScale()
  local info = currentOutputInfo()
  return (info and info.scale) or 1
end

-- group id -> member widget names; a monitor override may restyle a group without repeating its members
local function groupMembers(bar, override)
  local byId = {}
  for _, source in ipairs({ bar, override }) do
    for _, group in ipairs(source.capsule_group or {}) do
      if group.members then
        byId[group.id] = group.members
      end
    end
  end
  return byId
end

-- Finds this plugin's widget in the lanes, directly or inside a "group:<id>" capsule group.
-- Returns its instance name and whether it sits in a group.
local function laneHas(lanes, widgetNames, members)
  for _, lane in ipairs({ "start", "center", "end" }) do
    for _, token in ipairs(lanes[lane] or {}) do
      if widgetNames[token] then
        return token, false
      end

      local groupId = string.match(token, "^group:(.+)$")
      for _, member in ipairs(groupId and members[groupId] or {}) do
        if widgetNames[member] then
          return member, true
        end
      end
    end
  end
  return nil, false
end

local function monitorOverride(bar, currentOutput)
  local info = currentOutputInfo()
  local description = info and info.description or nil

  for key, override in pairs(bar.monitor or {}) do
    local match = override.match or key
    if match == currentOutput or (description and string.find(description, match, 1, true)) then
      return override
    end
  end
  return nil
end

-- Resolves usable bar thickness (accounting for per-monitor overrides and capsule mode)
-- alongside the multiplier applied to ui.* dimensions
local function findBarGeometry()
  local current = resolveOutput()
  local bars = noctalia.getSetting("bar")
  local widgets = noctalia.getSetting("widget")
  if current == nil or type(bars) ~= "table" or type(widgets) ~= "table" or PLUGIN_NAME == nil then
    return nil
  end

  local ownedWidgets = {}
  for name, cfg in pairs(widgets) do
    if type(cfg) == "table" and type(cfg.type) == "string"
      and string.find(cfg.type, "/" .. PLUGIN_NAME .. ":", 1, true) then
      ownedWidgets[name] = true
    end
  end

  for name, bar in pairs(bars) do
    if name ~= "order" and type(bar) == "table" then
      local override = monitorOverride(bar, current) or {}
      local members = groupMembers(bar, override)
      local instance, inGroup = laneHas(override, ownedWidgets, members)
      if not instance then
        instance, inGroup = laneHas(bar, ownedWidgets, members)
      end
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

        local capsule = inGroup or widgets[instance].capsule
        if capsule == nil then
          capsule = pick("capsule", false)
        end

        -- ui.* sizes scale with bar/widget scale, whereas raw bar thickness does not
        local contentScale = pick("scale", 1) * (widgets[instance].scale or 1)
        local thickness = pick("thickness", FALLBACK_HEIGHT)
        local fraction = capsule and pick("capsule_thickness", DEFAULT_CAPSULE_FRACTION) or 1
        return thickness * fraction, contentScale
      end
    end
  end

  return nil
end

local function barGeometry()
  if cachedHeight == nil then
    cachedHeight, cachedContentScale = findBarGeometry()
  end
  return cachedHeight or FALLBACK_HEIGHT, cachedContentScale or 1
end

local function computeLayout(blockHeight)
  local height, contentScale = barGeometry()
  local scale = outputScale()

  -- Whole device pixels, never more than the box. Any leftover is split by an explicit spacer in
  -- render(), so every block height step changes the size by whole pixels and stays centered.
  local boxPixels = math.floor(height * scale + 0.5)
  local blockPixels = math.max(1, math.floor(height * blockHeight * scale + 0.0001))
  local pixels = blockPixels / scale
  local vertical = barWidget.isVertical()

  -- At full height the block ends one pixel row short of the bar, so it gets one extra device pixel
  local full = blockHeight >= FULL_HEIGHT_EPSILON
  local bias = full and FULL_HEIGHT_BIAS / scale or 0

  -- Extra pixel of an odd leftover goes on top, since the block sat closer to the top before
  local offsetPixels = full and 0 or math.ceil((boxPixels - blockPixels) / 2)
  local outerPixels = math.max(boxPixels, blockPixels + (full and FULL_HEIGHT_BIAS or 0))

  return {
    thickness = (pixels + bias) / contentScale,
    offset = offsetPixels / scale / contentScale,
    outer = outerPixels / scale / contentScale,
    scale = scale,
    contentScale = contentScale,
    sizeProp = vertical and "width" or "height",
    lengthProp = vertical and "height" or "width",
    vertical = vertical,
  }
end

-- ui units that land on whole device pixels, so chip edges and the underline stay crisp
local function snapUi(layout, value)
  local unit = layout.scale * layout.contentScale
  return math.max(0, math.floor(value * unit + 0.5) / unit)
end

-- Configuration & workspace state

local function readConfig()
  local function stateColors(prefix)
    return {
      fg = noctalia.getConfig(prefix .. "_foreground"),
      bg = noctalia.getConfig(prefix .. "_background"),
      underline = noctalia.getConfig(prefix .. "_underline"),
    }
  end

  return {
    customLabels = noctalia.getConfig("custom_labels"),
    pillSizeMode = noctalia.getConfig("pill_size_mode"),
    activePadding = noctalia.getConfig("active_padding"),
    inactivePadding = noctalia.getConfig("inactive_padding"),
    activeLength = noctalia.getConfig("active_length"),
    inactiveLength = noctalia.getConfig("inactive_length"),
    fontMode = noctalia.getConfig("font_mode"),
    fontMin = noctalia.getConfig("font_min"),
    fontSize = noctalia.getConfig("font_size"),
    blockHeight = noctalia.getConfig("block_height"),
    showUnderline = noctalia.getConfig("show_underline"),
    underlineWidth = noctalia.getConfig("underline_width"),
    underlinePosition = noctalia.getConfig("underline_position"),
    backgroundOpacity = noctalia.getConfig("background_opacity"),
    radius = noctalia.getConfig("radius"),
    gap = noctalia.getConfig("gap"),
    showLabel = noctalia.getConfig("show_label"),
    colors = {
      focused = stateColors("focused"),
      occupied = stateColors("occupied"),
      empty = stateColors("empty"),
    },
  }
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

local function labelFor(ws, customLabels)
  return (customLabels and customLabels[ws.index]) or tostring(ws.index)
end

local function switchTo(ws)
  noctalia.umbriel.action({
    action = "workspace-switch",
    workspace = ws.index,
    output = ws.output,
  }, function(ok, err)
    if not ok then
      noctalia.log("workspace-switch failed: " .. tostring(err))
    end
  end)
end

local function progressOf(ws)
  if progress[ws.id] == nil then
    progress[ws.id] = ws.active and 1 or 0
  end
  return progress[ws.id]
end

-- UI rendering

local function buildChip(ws, layout, cfg)
  local state = ws.active and "focused" or (ws.occupied and "occupied" or "empty")
  local palette = cfg.colors[state]
  local eased = smoothstep(progressOf(ws))

  local pillMode = cfg.pillSizeMode == "Fixed_Length"
  -- a fixed length needs no padding: the label is centered in it
  local paddingH = snapUi(layout, pillMode and 0 or lerp(cfg.inactivePadding, cfg.activePadding, eased))
  local length = pillMode
    and snapUi(layout, layout.thickness * lerp(cfg.inactiveLength, cfg.activeLength, eased))
    or nil

  local alpha = (palette.bg == TRANSPARENT) and 0 or cfg.backgroundOpacity
  local fill = withAlpha(palette.bg, alpha)

  -- Underlines apply only at full block height
  local hasFullHeight = cfg.blockHeight >= FULL_HEIGHT_EPSILON
  local lineColor = hasFullHeight and palette.underline or TRANSPARENT
  local lineWidth = (hasFullHeight and cfg.showUnderline) and
    cfg.underlineWidth + (cfg.underlinePosition == "Top" and 1 or 0)
    or 0

  -- Boxes land on whole device pixels, so a fractional width would round away. Draw the next whole
  -- number of pixels and let the opacity carry the fraction (1.5 px -> 2 px at 75%).
  local lineHeight = 0
  if lineWidth > 0 then
    local devicePixels = lineWidth * layout.scale
    local wholePixels = math.max(1, math.ceil(devicePixels - 0.0001))
    lineColor = fade(lineColor, devicePixels / wholePixels)
    lineHeight = wholePixels / layout.scale / layout.contentScale
  end

  local fontSize = nil
  if cfg.fontMode == "Auto" then
    local innerRoom = layout.thickness - 2 * lineHeight
    fontSize = math.max(cfg.fontMin, math.floor(innerRoom * FONT_RATIO + 0.5))
  elseif cfg.fontMode == "Fixed" then
    fontSize = cfg.fontSize
  end

  -- Fixed_Length is exact: a label that does not fit is cut instead of stretching the pill
  local label = ui.label({
    text = cfg.showLabel and labelFor(ws, cfg.customLabels) or nil,
    maxWidth = length,
    fontSize = fontSize,
    color = palette.fg,
    fontWeight = ws.active and "bold" or nil,
  })

  local children = { label }
  if lineWidth > 0 then
    -- Mirror the underline with a transparent spacer on the opposite edge to keep the label centered
    local onTop = cfg.underlinePosition == "Top"
    children = {
      ui.box({ key = "line-top", height = lineHeight, fill = onTop and lineColor or TRANSPARENT }),
      ui.row({ flexGrow = 1, align = "center", justify = "center", paddingH = paddingH }, { label }),
      ui.box({ key = "line-bottom", height = lineHeight, fill = onTop and TRANSPARENT or lineColor }),
    }
  end

  -- Encode structural mode flags in the key so retained nodes reset dropped props cleanly
  local key = string.format(
    "ws-%s%s%s%s-chip",
    tostring(ws.id),
    ws.active and "-active" or "",
    pillMode and "-pill" or "",
    fontSize and "-fs" or ""
  )

  local props = {
    key = key,
    fill = fill,
    radius = math.min(cfg.radius, layout.thickness / 2),
    clip = pillMode, -- a fixed length is a hard limit: whatever does not fit is cut
    paddingH = lineWidth > 0 and 0 or paddingH,
    [layout.sizeProp] = layout.thickness,
    align = lineWidth > 0 and "stretch" or "center",
    justify = "center",
    onHover = "",
    onClick = function()
      switchTo(ws)
    end,
  }

  if length then
    props[layout.lengthProp] = length
  end

  -- Keep ui.column and ui.row calls separate to satisfy Luau's strict function union typing
  if lineWidth > 0 then
    return ui.column(props, children)
  end
  return ui.row(props, children)
end

local function render()
  local items = visibleWorkspaces()
  barWidget.setVisible(#items > 0)

  local cfg = readConfig()
  local layout = computeLayout(cfg.blockHeight)

  if cfg.underlineWidth ~= loggedUnderline then
    loggedUnderline = cfg.underlineWidth
    noctalia.log(string.format(
      "underline: setting=%s output scale=%s content scale=%s",
      tostring(cfg.underlineWidth), tostring(layout.scale), tostring(layout.contentScale)
    ))
  end
  local chips = {}

  for _, ws in ipairs(items) do
    table.insert(chips, buildChip(ws, layout, cfg))
  end

  local container = layout.vertical and ui.column or ui.row
  local inner = container({ gap = snapUi(layout, cfg.gap), align = "center" }, chips)

  -- Full-thickness wrapper with a spacer, so the block is centered instead of sitting at the top
  local spacer = ui.box({ key = "v-spacer", [layout.sizeProp] = layout.offset })
  local wrapper = layout.vertical and ui.row or ui.column
  barWidget.render(wrapper({ [layout.sizeProp] = layout.outer }, { spacer, inner }))
end

-- Animation loop

local function retarget()
  local duration = noctalia.getConfig("animation_duration")
  local moving = false

  for _, ws in ipairs(visibleWorkspaces()) do
    local target = ws.active and 1 or 0
    if progress[ws.id] ~= nil and progress[ws.id] ~= target then
      if duration > 0 then
        moving = true
      else
        progress[ws.id] = target
      end
    end
  end

  render()

  if moving then
    lastTickMs = noctalia.nowMs()
    animating = true
    noctalia.setUpdateInterval(FRAME_INTERVAL_MS)
  end
end

function update()
  if not animating then
    return
  end

  local now = noctalia.nowMs()
  local step = (now - lastTickMs) / noctalia.getConfig("animation_duration")
  lastTickMs = now

  local moving = false
  for _, ws in ipairs(visibleWorkspaces()) do
    local target = ws.active and 1 or 0
    local current = progressOf(ws)

    if current < target then
      current = math.min(target, current + step)
    elseif current > target then
      current = math.max(target, current - step)
    end

    progress[ws.id] = current
    moving = moving or current ~= target
  end

  render()

  if not moving then
    animating = false
    noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
  end
end

-- Compositor subscription

local function extractWorkspaces(payload)
  if type(payload) == "string" then
    payload = noctalia.json.decode(payload)
  end
  if type(payload) ~= "table" then
    return nil
  end

  local kind = payload.event or payload.type
  if kind ~= nil and kind ~= "workspaces" then
    return nil
  end

  local list = payload.data or payload.workspaces or (payload[1] ~= nil and payload) or nil
  return type(list) == "table" and list or nil
end

noctalia.compositor.subscribe({ events = { "workspaces" } }, function(first, second)
  local list = (first == "workspaces" and extractWorkspaces(second)) or extractWorkspaces(first)
  if list then
    workspaces = list
    retarget()
  end
end)

render()
