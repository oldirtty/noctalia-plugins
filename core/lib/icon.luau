--!nonstrict

-- Icon selection and rendering for Core: built-in/custom Tabler glyph,
-- or custom image (optionally tinted via ui.image colorize).

local I = {}

local DEFAULT_GLYPH = "adjustments-horizontal"

local function resolvePath(src: string): string
  local p = src:gsub("^file://", "")
  p = p:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16) :: number)
  end)
  p = noctalia.expandPath(p) or p
  if p:sub(1, 1) ~= "/" then
    local pdir = noctalia.pluginDir()
    if pdir then
      p = pdir .. "/" .. p
    end
  end
  return p
end

-- cfg: { glyph, image, colorize, size }
function I.node(cfg)
  local image = cfg.image
  if type(image) == "string" and image ~= "" then
    local path = resolvePath(image)
    return ui.image({
      key = "icon:" .. path,
      path = path,
      width = cfg.size,
      height = cfg.size,
      fit = "contain",
      colorize = cfg.colorize,
    })
  end

  local glyph = (type(cfg.glyph) == "string" and cfg.glyph ~= "") and cfg.glyph or DEFAULT_GLYPH
  return ui.glyph({ key = "icon:" .. glyph, name = glyph })
end

return I