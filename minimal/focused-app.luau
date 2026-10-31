--!nonstrict
local common = require("./lib/common.luau")

local FALLBACK = "Umbriel"

-- resolves an app_id to the Name= of its .desktop file ($1 = app_id): file named
-- after the id first, then a file whose StartupWMClass matches (e.g. zen, vlc)
local LOOKUP = [[
IFS=:
for d in "${XDG_DATA_HOME:-$HOME/.local/share}" ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do
  f="$d/applications/$1.desktop"
  [ -f "$f" ] || f=$(grep -lixF "StartupWMClass=$1" "$d"/applications/*.desktop 2>/dev/null | head -n 1)
  if [ -n "$f" ]; then
    grep -m1 '^Name=' "$f" | cut -d= -f2-
    exit
  fi
done
]]

-- last segments that say nothing about the app (org.gnome.seahorse.Application)
local GENERIC = { application = true, app = true, desktop = true }

local label = noctalia.getConfig("label") or "app"
local color = common.labelColor()

-- px limits, applied by common.tree through ui props (minWidth / maxWidth)
common.setWidth(noctalia.getConfig("min_width") or 0, noctalia.getConfig("max_width") or 0)

local names = {}   -- app_id -> resolved name
local current = nil

-- upper-cases the first letter of an all-lowercase name (kitty -> Kitty);
-- a name that already has capitals is kept as is (qBittorrent, VLC)
local function capitalize(name)
  if name:find("%u") then
    return name
  end
  return name:sub(1, 1):upper() .. name:sub(2)
end

-- last meaningful segment of the id (org.gnome.seahorse.Application -> seahorse)
local function mainSegment(appId)
  local main = appId
  for segment in appId:gmatch("[^%.]+") do
    if not GENERIC[segment:lower()] then
      main = segment
    end
  end
  return main
end

-- used until the lookup answers, and when there is no .desktop file
local function fallbackName(appId)
  return capitalize(mainSegment(appId))
end

-- Name= often adds a description ("mpv Media Player", "Zen Browser"): when one of
-- its words is the app itself, show only that word, otherwise the whole Name
local function displayName(name, appId)
  local main = mainSegment(appId):lower()
  for word in name:gmatch("%S+") do
    if word:lower() == main then
      return capitalize(word)
    end
  end
  return capitalize(name)
end

local function draw(value)
  barWidget.render(common.tree(barWidget.isVertical(), label, color, value))
end

local function lookup(appId)
  noctalia.runAsync({ "sh", "-c", LOOKUP, "sh", appId }, function(result)
    local name = noctalia.string.trim(result.stdout or "")
    names[appId] = name ~= "" and displayName(name, appId) or fallbackName(appId)
    if appId == current then
      draw(names[appId])
    end
  end)
end

local function onLine(line)
  local msg = noctalia.json.decode(line)
  if type(msg) ~= "table" or type(msg.data) ~= "table" then
    return
  end

  -- `active` is the one window with keyboard focus; `focused` is per output
  local appId = nil
  for _, w in ipairs(msg.data) do
    if w.active and w.app_id and w.app_id ~= "" then
      appId = w.app_id
      break
    end
  end

  if appId == current then
    return
  end
  current = appId

  if not appId then
    draw(FALLBACK)
  elseif names[appId] then
    draw(names[appId])
  else
    draw(fallbackName(appId))
    lookup(appId)
  end
end

draw(FALLBACK)
noctalia.runStream("umbriel subscribe windows", onLine)
