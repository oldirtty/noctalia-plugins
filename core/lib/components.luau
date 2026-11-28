--!nonstrict

-- Reusable pieces for Core. Styling follows the shell's global settings.

local C = {}

-- Hover state for interactive buttons; the panel sets C.onHover to re-render.
local hovered = {}
C.onHover = nil

function C.clearHover()
  hovered = {}
end

local function setHovered(key: string, active: boolean)
  if hovered[key] ~= active then
    hovered[key] = active
    if C.onHover then C.onHover() end
  end
end

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
  local badgeKey = key .. "-badge"
  local isHovered = onClick ~= nil and hovered[badgeKey] == true

  local fill = "outline_variant"
  local fg = "on_surface"

  if visualState == "active" then
    fill = "primary"
    fg = "on_primary"
  elseif visualState == "muted" then
    fill = "error"
    fg = "surface"
  end

  if isHovered then
    fill = "hover"
    fg = "on_hover"
  end

  local btnBorders = getBoolSetting("shell.button_borders", false)
  local showBorder = btnBorders and visualState == "disabled" and not isHovered

  return ui.row({
    key = badgeKey,
    width = 48,
    height = 48,
    radius = getSystemRadius(),
    align = "center",
    justify = "center",
    fill = fill,
    border = showBorder and "outline" or nil,
    borderWidth = showBorder and 1 or nil,
    onClick = onClick,
    onHover = onClick and function(state)
      setHovered(badgeKey, state == "true")
    end or nil,
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

-- Bare glyph in a column that stretches to its parent's height.
local function glyphButton(b)
  local isHovered = hovered[b.key] == true
  return ui.column({
    key = b.key,
    width = 28,
    radius = getSystemRadius(),
    fill = isHovered and "hover" or nil,
    align = "center",
    justify = "center",
    tooltip = b.tooltip,
    onClick = b.onClick,
    onHover = function(state)
      setHovered(b.key, state == "true")
    end,
  }, {
    ui.glyph({
      name = b.glyph,
      size = b.size or 21,
      color = isHovered and "on_hover" or "outline",
    }),
  })
end

-- Trailing buttons for tiles. a.buttons: { { key, glyph, tooltip, onClick, full, size }, ... }
-- full = true: bare glyph in a column that stretches to its parent's height.
local function trailingButtons(items, buttons)
  for _, b in ipairs(buttons or {}) do
    if b.full then
      table.insert(items, glyphButton(b))
    else
      table.insert(items, ui.button({ key = b.key, glyph = b.glyph, tooltip = b.tooltip, onClick = b.onClick }))
    end
  end
  return items
end

-- a: user, host, sub, tips { settings, session, close }, onSettings, onSession, onClose
function C.header(a)
  local circularAvatar = getBoolSetting("shell.circular_avatar", true)
  local showClose = getBoolSetting("shell.show_close_buttons", true)
  local showSettings = noctalia.getConfig("hide_settings_button") ~= true
  local showSession = noctalia.getConfig("hide_session_button") ~= true
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

  if showSession then
    table.insert(items, ui.button({
      key = "btn-session",
      glyph = "power",
      tooltip = a.tips.session,
      onClick = a.onSession,
    }))
  end

  if showClose then
    table.insert(items, ui.button({ key = "btn-close", glyph = "x", tooltip = a.tips.close, onClick = a.onClose }))
  end

  return ui.row({ key = "header", gap = 10, align = "center" }, items)
end

-- Only the badge (onClick/tooltip) and the trailing buttons are interactive.
-- a: key, glyph, title, subtitle, state ("active" | "muted" | "disabled"), onClick, tooltip, buttons
function C.tile(a)
  local visualState = a.state or (a.active and "active" or "disabled")
  return ui.row(box(a.key, {
    gap = 12,
    padding = 12,
    align = "stretch",
  }), trailingButtons({
    ui.column({ key = a.key .. "-badge-col", justify = "center" }, {
      badge(a.key, a.glyph, visualState, a.onClick, a.tooltip),
    }),
    titles(a.key, a.title, a.subtitle),
  }, a.buttons))
end

-- Compact action tile (3-col power modes, 6-col quick tiles)
-- a: key, glyph, label, active, onClick, tooltip, height, glyphSize, fontSize, gap
function C.actionTile(a)
  local active = a.active == true
  local isHovered = a.onClick ~= nil and hovered[a.key] == true

  local fill = active and "primary" or "surface_container"
  local fg = active and "on_primary" or "on_surface"

  if isHovered then
    fill = "hover"
    fg = "on_hover"
  end

  local extra = {
    _active = active,
    gap = a.gap or 6,
    paddingH = 8,
    align = "center",
    justify = "center",
    fill = fill,
    tooltip = a.tooltip,
    onClick = a.onClick,
    onHover = a.onClick and function(state)
      setHovered(a.key, state == "true")
    end or nil,
  }
  if a.height then
    extra.height = a.height
  else
    extra.paddingV = 8
  end

  return ui.column(box(a.key, extra), {
    ui.glyph({
      name = a.glyph,
      size = a.glyphSize or 20,
      color = fg,
    }),
    ui.label({
      text = a.label,
      fontSize = a.fontSize or 12,
      fontWeight = "medium",
      color = fg,
      textAlign = "center",
      maxLines = 1,
    }),
  })
end

-- Grid-like layout:
-- botao | Title
-- botao | Slider + % + arrow
-- a: key, glyph, title, state ("active" | "muted" | "disabled"), value, enabled,
--    onClick, tooltip, onChange, onEnd, headButtons (bare glyphs next to the title)
local function sliderRow(a)
  local enabled = a.enabled ~= false
  local visualState = a.state or (enabled and "active" or "disabled")
  local val = a.value or 0

  local headItems = {
    ui.label({
      text = a.title,
      fontSize = 14,
      fontWeight = "bold",
      flexGrow = 1,
      maxLines = 1,
    }),
  }
  trailingButtons(headItems, a.headButtons)

  local controlItems = {
    ui.column({ key = a.key .. "-slider-col", flexGrow = 1, justify = "center" }, {
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
    }),
    ui.column({ key = a.key .. "-value-col", justify = "center" }, {
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
  }

  return ui.row({ key = a.key, gap = 12, align = "center" }, {
    badge(a.key, a.glyph, visualState, a.onClick, a.tooltip),
    ui.column({
      key = a.key .. "-body",
      flexGrow = 1,
      gap = 0,
      justify = "center",
    }, {
      ui.row({
        key = a.key .. "-head",
        gap = 8,
        align = "center",
        paddingV = 4,
      }, headItems),
      ui.row({
        key = a.key .. "-control",
        gap = 8,
        align = "stretch",
        paddingV = -8,
      }, controlItems),
    }),
  })
end

-- One box holding one or more slider rows (same args as sliderTile, one per row).
-- sideButtons (full = true) become one column spanning the whole box height, so every
-- row gets the same width and the button centers on the block.
function C.sliderGroup(key, rows, sideButtons)
  local children = {}
  for _, a in ipairs(rows) do
    table.insert(children, sliderRow(a))
  end
  return ui.row(box(key, { gap = 8, padding = 12, align = "stretch" }), trailingButtons({
    ui.column({ key = key .. "-rows", flexGrow = 1, gap = 12, justify = "center" }, children),
  }, sideButtons))
end

-- a.buttons: side buttons (see sliderGroup)
function C.sliderTile(a)
  return C.sliderGroup(a.key .. "-box", { a }, a.buttons)
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
