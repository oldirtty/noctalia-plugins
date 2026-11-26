--!nonstrict

-- Icon selection and rendering for Core: built-in/custom Tabler glyph,
-- or custom image (optionally tinted with the theme's on_surface).

local I = {}

local DEFAULT_GLYPH = "adjustments-horizontal"

local readyCache: { [string]: string } = {}
local pending: { [string]: boolean } = {}
local failed: { [string]: boolean } = {}
local magick: string | boolean | nil = nil

local function hash(s: string): number
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) % 4294967296
  end
  return h
end

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

local function imageMagick(): string | boolean
  if magick == nil then
    if noctalia.commandExists("magick") then
      magick = "magick"
    elseif noctalia.commandExists("convert") then
      magick = "convert"
    else
      magick = false
      noctalia.log("Colorize Custom Image needs ImageMagick (magick or convert) for raster images")
    end
  end
  return magick
end

local function tintSvgContent(svg: string, color: string): string
  -- If the SVG already uses currentColor, replace only currentColor so
  -- intentional contrast fills (e.g. #000000 inner details) remain intact.
  if svg:find("[cC][uU][rR][rR][eE][nN][tT][cC][oO][lL][oO][rR]") then
    return (svg:gsub("[cC][uU][rR][rR][eE][nN][tT][cC][oO][lL][oO][rR]", color))
  end

  svg = svg:gsub('(fill%s*=%s*["\'])([^"\']+)(["\'])', function(pre, val, post)
    local low = val:lower()
    if low == "none" or low == "transparent" then return pre .. val .. post end
    return pre .. color .. post
  end)
  svg = svg:gsub('(stroke%s*=%s*["\'])([^"\']+)(["\'])', function(pre, val, post)
    local low = val:lower()
    if low == "none" or low == "transparent" then return pre .. val .. post end
    return pre .. color .. post
  end)
  svg = svg:gsub("(fill%s*:%s*)([^;\"']+)", function(pre, val)
    local trimmed = val:match("^%s*(.-)%s*$"):lower()
    if trimmed == "none" or trimmed == "transparent" then return pre .. val end
    return pre .. color
  end)
  svg = svg:gsub("(stroke%s*:%s*)([^;\"']+)", function(pre, val)
    local trimmed = val:match("^%s*(.-)%s*$"):lower()
    if trimmed == "none" or trimmed == "transparent" then return pre .. val end
    return pre .. color
  end)
  svg = svg:gsub("<svg([^>]*)>", function(attrs)
    if not attrs:find("fill%s*=") and not attrs:find("stroke%s*=") then
      return '<svg' .. attrs .. ' fill="' .. color .. '">'
    end
    return "<svg" .. attrs .. ">"
  end, 1)

  return svg
end

local function tinted(src: string, onReady: () -> ()): string
  local resolvedSrc = resolvePath(src)
  local color = noctalia.getColor("on_surface")
  local dir = noctalia.pluginDataDir()
  if not color or not dir then
    return resolvedSrc
  end

  local cacheKey = resolvedSrc .. "|" .. color
  if readyCache[cacheKey] then
    return readyCache[cacheKey]
  end
  if pending[cacheKey] or failed[cacheKey] then
    return resolvedSrc
  end

  local isSvg = resolvedSrc:lower():match("%.svg$") ~= nil
  local keyHash = hash(cacheKey)

  if isSvg then
    local out = string.format("%s/tint-%08x.svg", dir, keyHash)
    if noctalia.fileExists(out) then
      readyCache[cacheKey] = out
      return out
    end

    local raw = noctalia.readFile(resolvedSrc)
    if not raw or raw == "" then
      failed[cacheKey] = true
      return resolvedSrc
    end

    local colored = tintSvgContent(raw, color)
    if noctalia.writeFile(out, colored) then
      readyCache[cacheKey] = out
      return out
    end

    -- Ensure plugin data directory exists on first write, then retry once.
    pending[cacheKey] = true
    noctalia.runAsync({ "mkdir", "-p", dir }, function(res)
      pending[cacheKey] = nil
      if res and res.exitCode == 0 and noctalia.writeFile(out, colored) then
        readyCache[cacheKey] = out
        onReady()
      else
        failed[cacheKey] = true
      end
    end)
    return resolvedSrc
  end

  local out = string.format("%s/tint-%08x.png", dir, keyHash)
  if noctalia.fileExists(out) then
    readyCache[cacheKey] = out
    return out
  end

  local bin = imageMagick()
  if not bin then
    failed[cacheKey] = true
    return resolvedSrc
  end

  pending[cacheKey] = true
  local cmd = string.format(
    "mkdir -p %q && %s %q -colorspace sRGB -fill %q -colorize 100 %q",
    dir,
    bin,
    resolvedSrc,
    color,
    "PNG32:" .. out
  )
  noctalia.runAsync(cmd, function(res)
    pending[cacheKey] = nil
    if res and res.exitCode == 0 and noctalia.fileExists(out) then
      readyCache[cacheKey] = out
    else
      failed[cacheKey] = true
      noctalia.log("tint failed: " .. ((res and res.stderr) or ""))
    end
    onReady()
  end)
  return resolvedSrc
end

-- cfg: { glyph, image, colorize, size }
function I.node(cfg, onReady)
  local image = cfg.image
  if type(image) == "string" and image ~= "" then
    local path = cfg.colorize and tinted(image, onReady) or resolvePath(image)
    return ui.image({
      key = "icon:" .. path,
      path = path,
      width = cfg.size,
      height = cfg.size,
      fit = "contain",
    })
  end

  local glyph = (type(cfg.glyph) == "string" and cfg.glyph ~= "") and cfg.glyph or DEFAULT_GLYPH
  return ui.glyph({ key = "icon:" .. glyph, name = glyph })
end

return I
