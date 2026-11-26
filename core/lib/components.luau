--!nonstrict

-- Reusable pieces for Core. Styling follows the shell's global settings.

local C = {}

local function getSystemRadius(): number
  local setting = noctalia.getSetting("shell.corner_radius_scale")
  local factor = (setting ~= nil) and tonumber(setting) or 1.0
  return math.floor(8 * factor + 0.5)
end

local function getBoolSetting(path: string, defaultVal: boolean): boolean
  local val = noctalia.getSetting(path)
  if val == nil then
    return defaultVal
  end
  return val == true
end

local function cardBorder(active: boolean?): (string?, number?)
  if not getBoolSetting("shell.card_borders", true) then
    return nil, nil
  end
  return active and "primary" or "outline_variant", 1
end

local function box(key, extra)
  local borderColor, borderWidth = cardBorder(extra and extra._active)
  local p = {
    key = key,
    flexGrow = 1,
    fill = "surface_container",
    radius = getSystemRadius(),
    border = borderColor,
    borderWidth = borderWidth,
  }
  for k, v in pairs(extra) do
    if k ~= "_active" then
      p[k] = v
    end
  end
  return p
end

-- visualState: "active" | "muted" | "disabled"
local function badge(key, glyph, visualState, onClick, tooltip)
  local fill = "outline_variant"
  local fg = "on_surface"

  if visualState == "active" then
    fill = "primary"
    fg = "on_primary"
  elseif visualState == "muted" then
    fill = "error"
    fg = "surface"
  end

  local btnBorders = getBoolSetting("shell.button_borders", false)
  local showBorder = btnBorders and visualState == "disabled"

  return ui.row({
    key = key .. "-badge",
    width = 48,
    height = 48,
    radius = getSystemRadius(),
    align = "center",
    justify = "center",
    fill = fill,
    border = showBorder and "outline" or nil,
    borderWidth = showBorder and 1 or nil,
    onClick = onClick,
    tooltip = tooltip,
  }, {
    ui.glyph({
      name = glyph,
      size = 21,
      color = fg,
    }),
  })
end

local function titles(key, title, subtitle)
  return ui.column({ key = key .. "-text", flexGrow = 1, justify = "center" }, {
    ui.label({
      text = title,
      fontSize = 14,
      fontWeight = "bold",
      maxLines = 1,
    }),
    ui.label({
      text = subtitle,
      fontSize = 14,
      color = "on_surface_variant",
      maxLines = 1,
    }),
  })
end

-- a: user, host, sub, tips { settings, close }, onSettings, onClose
function C.header(a)
  local circularAvatar = getBoolSetting("shell.circular_avatar", true)
  local showClose = getBoolSetting("shell.show_close_buttons", true)
  local showSettings = noctalia.getConfig("hide_settings_button") ~= true
  local avatarPath = noctalia.getSetting("shell.avatar_path")
  local avatarRadius = circularAvatar and 26 or getSystemRadius()

  local avatar
  local path = avatarPath and noctalia.expandPath(avatarPath)
  if path and noctalia.fileExists(path) then
    avatar = ui.image({
      key = "avatar",
      path = path,
      width = 52,
      height = 52,
      fit = "cover",
      radius = avatarRadius,
    })
  else
    avatar = ui.row({
      key = "avatar",
      width = 52,
      height = 52,
      align = "center",
      justify = "center",
      fill = "surface_container_high",
      radius = avatarRadius,
    }, {
      ui.glyph({ name = "user", size = 24, color = "on_surface" }),
    })
  end

  local items = {
    avatar,
    ui.column({ key = "who", flexGrow = 1, justify = "center" }, {
      ui.label({ text = a.user .. "@" .. a.host, fontSize = 16, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = a.sub, fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
    }),
  }

  if showSettings then
    table.insert(items, ui.button({ key = "btn-settings", glyph = "settings", tooltip = a.tips.settings, onClick = a.onSettings }))
  end

  if showClose then
    table.insert(items, ui.button({ key = "btn-close", glyph = "x", tooltip = a.tips.close, onClick = a.onClose }))
  end

  return ui.row({ key = "header", gap = 10, align = "center" }, items)
end

-- a: key, glyph, title, subtitle, state ("active" | "muted" | "disabled"), onClick, tooltip
function C.tile(a)
  local visualState = a.state or (a.active and "active" or "disabled")
  return ui.row(box(a.key, {
    gap = 12,
    padding = 12,
    align = "center",
    tooltip = a.tooltip,
    onClick = a.onClick,
  }), {
    badge(a.key, a.glyph, visualState),
    titles(a.key, a.title, a.subtitle),
  })
end

-- Compact square-ish action tile (used for 3-col power modes, 4-col toggles)
-- a: key, glyph, label, active, onClick, tooltip
function C.actionTile(a)
  local active = a.active == true
  return ui.column(box(a.key, {
    _active = active,
    gap = 8,
    paddingV = 14,
    paddingH = 6,
    align = "center",
    justify = "center",
    fill = active and "primary" or "surface_container",
    tooltip = a.tooltip,
    onClick = a.onClick,
  }), {
    ui.glyph({
      name = a.glyph,
      size = 21,
      color = active and "on_primary" or "on_surface",
    }),
    ui.label({
      text = a.label,
      fontSize = 12,
      fontWeight = "medium",
      color = active and "on_primary" or "on_surface",
      maxLines = 1,
    }),
  })
end

-- Square icon-only action tile (used for the vertical session column)
-- a: key, glyph, active, onClick, tooltip
function C.iconTile(a)
  local active = a.active == true
  return ui.column(box(a.key, {
    _active = active,
    align = "center",
    justify = "center",
    fill = active and "primary" or "surface_container",
    tooltip = a.tooltip,
    onClick = a.onClick,
  }), {
    ui.glyph({
      name = a.glyph,
      size = 21,
      color = active and "on_primary" or "on_surface",
    }),
  })
end

-- Grid-like layout:
-- botao | Title
-- botao | Slider + %
-- a: key, glyph, title, state ("active" | "muted" | "disabled"), value, enabled,
--    onClick, tooltip, onChange, onEnd
function C.sliderTile(a)
  local enabled = a.enabled ~= false
  local visualState = a.state or (enabled and "active" or "disabled")
  local val = a.value or 0

  return ui.row(box(a.key, { gap = 12, padding = 12, align = "center" }), {
    badge(a.key, a.glyph, visualState, a.onClick, a.tooltip),
    ui.column({
      key = a.key .. "-body",
      flexGrow = 1,
      gap = 0,
      justify = "center",
    }, {
      ui.row({
        key = a.key .. "-head",
        align = "center",
        tooltip = a.tooltip,
        onClick = a.onClick,
        paddingV = 4,
      }, {
        ui.label({
          text = a.title,
          fontSize = 14,
          fontWeight = "bold",
          flexGrow = 1,
          maxLines = 1,
        }),
      }),
      ui.row({
        key = a.key .. "-control",
        gap = 8,
        align = "center",
        paddingV = -8,
      }, {
        ui.slider({
          key = a.key .. "-slider",
          flexGrow = 1,
          min = 0,
          max = 100,
          step = 1,
          value = val,
          enabled = enabled,
          onChange = a.onChange,
          onDragEnd = a.onEnd,
        }),
        ui.label({
          key = a.key .. "-value",
          text = tostring(val) .. "%",
          width = 38,
          fontSize = 13,
          fontWeight = "medium",
          color = "on_surface",
          textAlign = "end",
          maxLines = 1,
        }),
      }),
    }),
  })
end

-- groups: array of rows; each row is { item1, item2, ..., cols = N } (default cols = 2).
function C.grid(groups)
  local rows = {}
  for i, g in ipairs(groups) do
    local cols = g.cols or 2
    local hasAny = false
    for c = 1, cols do
      if g[c] ~= nil then
        hasAny = true
        break
      end
    end
    if hasAny then
      local cells = {}
      for c = 1, cols do
        table.insert(cells, g[c] or ui.spacer({ flexGrow = 1 }))
      end
      table.insert(rows, ui.row({ key = "grid-" .. i, gap = 10 }, cells))
    end
  end
  return rows
end

return C
