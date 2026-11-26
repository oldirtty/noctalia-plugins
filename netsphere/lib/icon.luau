--!nonstrict

-- Icon selection and rendering for Netsphere: built-in Tabler glyph, custom
-- glyph, or custom image (optionally tinted with the theme's on_surface).

local I = {}

local DEFAULT = {
  wifi_strong = "wifi",
  wifi_medium = "wifi-2",
  wifi_weak = "wifi-1",
  wifi_disconnected = "wifi-0",
  ethernet = "sitemap",
  off = "wifi-off",
}

local readyCache = {}
local pending = {}
local failed = {}
local magick = nil -- "magick" | "convert" | false (looked up once)

function I.slot(S)
  if S.mode == "wired" then return "ethernet" end
  if S.mode == "off" then return "off" end
  if not S.connected then return "wifi_disconnected" end
  local signal = S.signal or 100
  if signal >= 67 then return "wifi_strong" end
  if signal >= 34 then return "wifi_medium" end
  return "wifi_weak"
end

local function hash(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + string.byte(s, i)) % 4294967296
  end
  return h
end

local function resolvePath(src)
  local p = src:gsub("^file://", "")
  p = p:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
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

local function imageMagick()
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

local function tintSvgContent(svg, color)
  -- Preserve intentional contrast fills (e.g. #000000 inner details) when
  -- the SVG already marks its primary layer with currentColor.
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

local function tinted(src, onReady)
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
  noctalia.runAsync({ "mkdir", "-p", dir }, function()
    noctalia.runAsync({
      bin,
      resolvedSrc,
      "-colorspace", "sRGB",
      "-fill", color,
      "-colorize", "100",
      "PNG32:" .. out,
    }, function(res)
      pending[cacheKey] = nil
      if res and res.exitCode == 0 and noctalia.fileExists(out) then
        readyCache[cacheKey] = out
      else
        failed[cacheKey] = true
        noctalia.log("tint failed: " .. ((res and res.stderr) or ""))
      end
      onReady()
    end)
  end)
  return resolvedSrc
end

-- cfg: { glyphs = {slot = name}, images = {slot = path}, colorize, size }
function I.node(slot, cfg, onReady)
  local image = cfg.images and cfg.images[slot]
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

  local glyph = cfg.glyphs and cfg.glyphs[slot]
  if not glyph or glyph == "" then glyph = DEFAULT[slot] or "wifi" end
  return ui.glyph({ key = "icon:" .. glyph, name = glyph })
end

return I
