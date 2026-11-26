--!nonstrict

-- Dynamic localization loader driven by shell.lang.

local M = {}

local cachedLang: string? = nil
local cachedDict: { [string]: string } = {}
local fallbackDict: { [string]: string }? = nil

local function loadJsonDict(relPath: string): { [string]: string }?
  if not noctalia.fileExists(relPath) then
    return nil
  end
  local raw = noctalia.readFile(relPath)
  if not raw or raw == "" then
    return nil
  end
  local decoded = noctalia.json.decode(raw)
  if type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function ensureFallback(): { [string]: string }
  if fallbackDict == nil then
    fallbackDict = loadJsonDict("translations/en.json") or {}
  end
  return fallbackDict
end

local function resolveLang(): string
  local setting = noctalia.getSetting("shell.lang")
  if type(setting) == "string" then
    local trimmed = noctalia.string.trim(setting)
    if trimmed ~= "" then
      return trimmed
    end
  end

  local env = noctalia.getenv("LC_ALL") or noctalia.getenv("LC_MESSAGES") or noctalia.getenv("LANG")
  if env and env ~= "" then
    local stripped = string.match(env, "^([^%.@]+)")
    if stripped and stripped ~= "" then
      return stripped
    end
  end

  return "en"
end

local function candidatesFor(lang: string): { string }
  local list = {}
  local seen = {}

  local function add(code: string?)
    if code and code ~= "" and not seen[code] then
      seen[code] = true
      table.insert(list, code)
    end
  end

  add(lang)
  add(string.lower(lang))

  local underscored = string.gsub(lang, "%-", "_")
  add(underscored)
  add(string.lower(underscored))

  local hyphenated = string.gsub(lang, "_", "-")
  add(hyphenated)
  add(string.lower(hyphenated))

  local base = string.match(lang, "^([a-zA-Z]+)[%-_]")
  if base then
    add(string.lower(base))
    add(base)
  end

  return list
end

local function syncDictionary()
  local lang = resolveLang()
  if lang == cachedLang then
    return
  end

  cachedLang = lang
  local fb = ensureFallback()

  if lang == "en" then
    cachedDict = fb
    return
  end

  for _, code in ipairs(candidatesFor(lang)) do
    local dict = loadJsonDict("translations/" .. code .. ".json")
    if dict then
      cachedDict = dict
      return
    end
  end

  cachedDict = fb
end

function M.lang(): string
  return resolveLang()
end

function M.tr(key: string, subst: { [string]: any }?): string
  syncDictionary()
  local fb = ensureFallback()
  local text = cachedDict[key] or fb[key]

  if type(text) ~= "string" then
    return noctalia.tr(key, subst)
  end

  if subst then
    for k, v in pairs(subst) do
      local safeVal = string.gsub(tostring(v), "%%", "%%%%")
      text = string.gsub(text, "{" .. k .. "}", safeVal)
    end
  end

  return text
end

return M
