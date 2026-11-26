--!nonstrict

local sys = require("./lib/system.luau")
local C = require("./lib/components.luau")
local i18n = require("./lib/i18n.luau")

local tr = i18n.tr
local S = sys.state
local isOpen = false

-- Fallback helper for translation keys not yet added to translations/*.json
local function trOr(key, fallback)
  local v = tr(key)
  return (v ~= nil and v ~= "" and v ~= key) and v or fallback
end

-- Tabler glyph names, in one place so a wrong name is a one-line fix.
local G = {
  vol = "volume",
  volOff = "volume-off",
  bright = "brightness-high",
  arrow = "chevron-right",
  wifi = "wifi",
  wifiOff = "wifi-off",
  ethernet = "ethernet",
  bt = "bluetooth",
  btOff = "bluetooth-off",
  powerSaver = "leaf",
  powerBalanced = "scale",
  powerPerformance = "bolt",
  themeDark = "nightlight-forced",
  themeLight = "brightness-2",
  themeAuto = "contrast",
  dnd = "bell-off",
  dndOff = "bell",
  caffeine = "mug",
  nightLight = "moon-filled",
  nightLightOff = "moon-off",
  wallpaper = "photo",
  clipboard = "clipboard",
}

-- ---------- Shell & Control Center shortcuts ----------

C.onHover = function()
  if isOpen then render() end
end

-- tab: Noctalia Control Center context (audio, monitor, network, bluetooth)
local function openControlCenter(tab)
  panel.close()
  noctalia.runAsync({ "noctalia", "msg", "panel-open", "control-center", tab })
end

-- name: Noctalia shell panel id (session, wallpaper, clipboard)
local function openPanel(name)
  panel.close()
  noctalia.runAsync({ "noctalia", "msg", "panel-toggle", name })
end

local function openButton(key, tab)
  return {
    key = key .. "-open",
    glyph = G.arrow,
    full = true,
    tooltip = tr("core.tip.open_panel"),
    onClick = function() openControlCenter(tab) end,
  }
end

-- ---------- sliders: audio & brightness ----------

local function audioTile()
  local muted = S.volMuted
  local onChange, onEnd = sys.slider("vol")

  local visualState = "disabled"
  if S.audioReady then
    visualState = muted and "muted" or "active"
  end

  return C.sliderTile({
    key = "t-vol",
    glyph = muted and G.volOff or G.vol,
    title = tr("core.audio"),
    state = visualState,
    value = S.vol,
    enabled = S.audioReady,
    tooltip = tr("core.tip.mute"),
    onClick = function() sys.toggle("vol") end,
    onChange = onChange,
    onEnd = onEnd,
    buttons = { openButton("t-vol", "audio") },
  })
end

local function firstReadyMonitor()
  for _, m in ipairs(S.monitors) do
    if m.ready then return m end
  end
  return S.monitors[1]
end

-- One slider for every monitor (system.luau always runs in sync mode).
local function brightnessTile()
  local mon = firstReadyMonitor()
  local ready = mon ~= nil and mon.ready
  local onChange, onEnd
  if ready then onChange, onEnd = sys.monitorSlider(mon) end

  return C.sliderTile({
    key = "t-bri",
    glyph = G.bright,
    title = tr("core.brightness"),
    state = ready and "active" or "disabled",
    value = mon and mon.value or 0,
    enabled = ready,
    tooltip = tr("core.tip.brightness_preset"),
    onClick = function() sys.applyBrightnessPreset(mon) end,
    onChange = onChange,
    onEnd = onEnd,
    buttons = { openButton("t-bri", "monitor") },
  })
end

-- ---------- connectivity ----------

local function netTile()
  local n = S.net
  local onCycle = function() sys.cycleNetwork() end
  local netButtons = { openButton("t-net", "network") }

  if n.kind == "ethernet" then
    return C.tile({
      key = "t-net",
      glyph = G.ethernet,
      title = tr("core.ethernet"),
      subtitle = n.name ~= "" and n.name or tr("core.connected"),
      state = "active",
      tooltip = tr("core.tip.network_cycle"),
      onClick = onCycle,
      buttons = netButtons,
    })
  end

  if n.kind == "wifi" or S.wifi then
    return C.tile({
      key = "t-net",
      glyph = G.wifi,
      title = tr("core.network"),
      subtitle = n.name ~= "" and n.name or tr("core.network.none"),
      state = "active",
      tooltip = tr("core.tip.network_cycle"),
      onClick = onCycle,
      buttons = netButtons,
    })
  end

  return C.tile({
    key = "t-net",
    glyph = G.wifiOff,
    title = tr("core.network"),
    subtitle = tr("core.off"),
    state = "disabled",
    tooltip = tr("core.tip.network_cycle"),
    onClick = onCycle,
    buttons = netButtons,
  })
end

local function btTile()
  local subtitle = tr("core.off")
  if S.bt then
    subtitle = S.btc > 0 and tr("core.bt.connected", { count = S.btc }) or tr("core.bt.none")
  end
  return C.tile({
    key = "t-bt",
    glyph = S.bt and G.bt or G.btOff,
    title = tr("core.bluetooth"),
    subtitle = subtitle,
    state = S.bt and "active" or "disabled",
    tooltip = tr("core.tip.bt_toggle"),
    onClick = function() sys.toggle("bt") end,
    buttons = { openButton("t-bt", "bluetooth") },
  })
end

-- ---------- power profiles (3 cols, shown when laptop battery exists) ----------

local function powerProfileRow()
  if not S.hasBattery then return nil end
  local function pBtn(key, profile, glyph, label)
    return C.actionTile({
      key = key,
      glyph = glyph,
      label = label,
      height = 56,
      active = S.powerProfile == profile,
      onClick = function() sys.setPowerProfile(profile) end,
    })
  end

  return {
    pBtn("p-saver", "power-saver", G.powerSaver, tr("core.power.saver")),
    pBtn("p-balanced", "balanced", G.powerBalanced, tr("core.power.balanced")),
    pBtn("p-perf", "performance", G.powerPerformance, tr("core.power.performance")),
    cols = 3,
  }
end

-- ---------- quick toggles & shortcuts (6 tiles: 96.3 x 78 px, ~1.23:1) ----------

local function quickToggleRow()
  local themeGlyph = G.themeDark
  local themeLabel = tr("core.theme.dark")
  if S.themeMode == "light" then
    themeGlyph = G.themeLight
    themeLabel = tr("core.theme.light")
  elseif S.themeMode == "auto" then
    themeGlyph = G.themeAuto
    themeLabel = tr("core.theme.auto")
  end

  local function quickTile(opts)
    opts.height = 64
    opts.glyphSize = 20
    opts.fontSize = 10.5
    opts.gap = 4
    return C.actionTile(opts)
  end

  return {
    quickTile({
      key = "q-clipboard",
      glyph = G.clipboard,
      label = trOr("core.clipboard", "Clipboard"),
      active = false,
      onClick = function() openPanel("clipboard") end,
    }),
    quickTile({
      key = "q-wallpaper",
      glyph = G.wallpaper,
      label = trOr("core.wallpaper", "Wallpaper"),
      active = false,
      onClick = function() openPanel("wallpaper") end,
    }),
    quickTile({
      key = "q-caffeine",
      glyph = G.caffeine,
      label = tr("core.caffeine"),
      active = S.caffeine,
      onClick = function() sys.toggle("caffeine") end,
    }),
    quickTile({
      key = "q-dnd",
      glyph = S.dnd and G.dnd or G.dndOff,
      label = tr("core.dnd"),
      active = S.dnd,
      onClick = function() sys.toggle("dnd") end,
    }),
    quickTile({
      key = "q-nightlight",
      glyph = S.nightLight and G.nightLight or G.nightLightOff,
      label = tr("core.night_light"),
      active = S.nightLight,
      onClick = function() sys.toggle("nightLight") end,
    }),
    quickTile({
      key = "q-theme",
      glyph = themeGlyph,
      label = themeLabel,
      active = S.themeMode ~= "auto",
      tooltip = tr("core.tip.theme_cycle"),
      onClick = function() sys.cycleThemeMode() end,
    }),
    cols = 6,
  }
end

-- ---------- header & render ----------

local function header()
  local host = noctalia.readFile("/etc/hostname")
  host = host and noctalia.string.trim(host) or (noctalia.getenv("HOSTNAME") or "")
  local sub = tr("core.up", { time = S.uptime })
  local desktop = string.lower(noctalia.getenv("XDG_CURRENT_DESKTOP") or "")
  if desktop ~= "" then sub = desktop .. " · " .. sub end

  return C.header({
    user = noctalia.getenv("USER") or "user",
    host = host,
    sub = sub,
    tips = {
      settings = tr("core.tip.settings"),
      session = tr("core.tip.session"),
      close = tr("core.tip.close"),
    },
    onSettings = function() noctalia.openSettings() end,
    onSession = function() openPanel("session") end,
    onClose = function() panel.close() end,
  })
end

function render()
  local groups = {
    { audioTile(), cols = 1 },
  }

  table.insert(groups, { brightnessTile(), cols = 1 })

  table.insert(groups, { netTile(), btTile() })

  local pRow = powerProfileRow()
  if pRow then
    table.insert(groups, pRow)
  end

  table.insert(groups, quickToggleRow())

  panel.render(ui.column({ gap = 12 }, {
    header(),
    ui.column({ key = "main-col", gap = 10 }, C.grid(groups)),
  }))
end

-- Update immediately on user interaction; skip background poll renders mid-drag.
sys.onChange = function(fromUser)
  if not isOpen then return end
  if fromUser or not sys.isDragging() then
    render()
  end
end

function onOpen()
  isOpen = true
  noctalia.setUpdateInterval(250)
  render()
  sys.open()
end

function onClose()
  isOpen = false
  sys.close()
end

function update()
  if isOpen then
    local interval = (noctalia.getConfig("refresh_seconds") or 2) * 1000
    sys.tick(interval)
  end
end
