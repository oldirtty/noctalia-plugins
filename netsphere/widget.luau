--!nonstrict

local net = require("./lib/network.luau")
local icon = require("./lib/icon.luau")

local tr = noctalia.tr
local S = net.state

local SLOTS = { "wifi_strong", "wifi_medium", "wifi_weak", "wifi_disconnected", "ethernet", "off" }

local cfg = {
  showLabel = noctalia.getConfig("show_label") ~= false,
  glyphAfter = noctalia.getConfig("glyph_position") == "after",
  peek = noctalia.getConfig("peek") == true,
  peekDelay = noctalia.getConfig("peek_delay_ms") or 100,
  hideOff = noctalia.getConfig("hide_when_off") == true,
  hideDisconnected = noctalia.getConfig("hide_when_disconnected") == true,
  colorize = noctalia.getConfig("colorize_custom_image") == true,
  size = noctalia.getConfig("image_size") or 16,
  glyphs = {},
  images = {},
}
for _, slot in ipairs(SLOTS) do
  cfg.glyphs[slot] = noctalia.getConfig("glyph_" .. slot)
  cfg.images[slot] = noctalia.getConfig("image_" .. slot)
end

local TICK_MS = 1000
local peeking = cfg.showLabel and cfg.peek
local hovering = false
local revealed = false
local hoverSince = 0

local render

-- ---------- text ----------

local function labelText()
  if S.mode == "wired" then return tr("net.wired") end
  if S.mode == "off" then return tr("net.off") end
  if S.connected and S.ssid ~= "" then return S.ssid end
  return tr("net.disconnected")
end

-- Side bars have no room: three characters, cut on a character boundary.
local function truncate3(s)
  local cut = utf8 and utf8.offset(s, 4)
  return cut and string.sub(s, 1, cut - 1) or s
end

local function tooltip()
  if S.mode == "off" then
    return { { tr("tip.network"), tr("net.off") } }
  end

  local kind = S.mode == "wired" and tr("net.wired")
    or (S.connected and tr("net.wifi") or tr("net.wifi_disconnected"))
  local rows = { { tr("tip.network"), kind } }

  if S.mode == "wifi" and S.connected then
    if S.ssid ~= "" then table.insert(rows, { tr("tip.ssid"), S.ssid }) end
    if S.signal then table.insert(rows, { tr("tip.signal"), S.signal .. "%" }) end
  end
  if S.iface then
    table.insert(rows, { tr("tip.interface"), S.iface })
    table.insert(rows, { tr("tip.ip"), S.ip or "-" })
    table.insert(rows, { tr("tip.download"), net.formatRate(S.rx) })
    table.insert(rows, { tr("tip.upload"), net.formatRate(S.tx) })
  end
  return rows
end

-- ---------- render ----------

render = function()
  local hidden = (cfg.hideOff and S.mode == "off")
    or (cfg.hideDisconnected and S.mode == "wifi" and not S.connected)
  barWidget.setVisible(not hidden)
  if hidden then return end

  local children = {}
  local iconNode = icon.node(icon.slot(S), cfg, render)
  local labelNode = nil
  if cfg.showLabel and (not cfg.peek or revealed) then
    local text = labelText()
    if barWidget.isVertical() then text = truncate3(text) end
    labelNode = ui.label({ key = "label", text = text })
  end

  if cfg.glyphAfter then
    if labelNode then table.insert(children, labelNode) end
    table.insert(children, iconNode)
  else
    table.insert(children, iconNode)
    if labelNode then table.insert(children, labelNode) end
  end

  local container = barWidget.isVertical() and ui.column or ui.row
  barWidget.render(container({
    key = "root",
    gap = 6,
    align = "center",
    onHover = peeking and "onWidgetHover" or nil,
  }, children))
  barWidget.setTooltip(tooltip())
end

-- ---------- callbacks ----------

function onWidgetHover(state)
  if not peeking then return end
  if state == "true" then
    hovering = true
    hoverSince = noctalia.nowMs()
    if cfg.peekDelay <= 0 then
      revealed = true
    else
      noctalia.setUpdateInterval(50) -- fine tick only while waiting for the delay
    end
  else
    hovering = false
    revealed = false
    noctalia.setUpdateInterval(TICK_MS)
  end
  render()
end

function update()
  net.tick()
  if hovering and not revealed and noctalia.nowMs() - hoverSince >= cfg.peekDelay then
    revealed = true
    noctalia.setUpdateInterval(TICK_MS)
  end
  render()
end

-- Wired -> Wi-Fi -> Off -> ... (a user binding for `right` takes precedence)
function onRightClick()
  net.cycle()
end

-- ---------- start ----------

noctalia.setUpdateInterval(TICK_MS)
net.onChange = render
net.start()
render()
