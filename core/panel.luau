--!nonstrict

local sys = require("./lib/system.luau")
local C = require("./lib/components.luau")
local i18n = require("./lib/i18n.luau")

local tr = i18n.tr
local S = sys.state
local isOpen = false

-- Tabler glyph names, in one place so a wrong name is a one-line fix.
local G = {
  vol = "volume",
  volOff = "volume-off",
  mic = "microphone",
  micOff = "microphone-off",
  bright = "sun",
  monitor = "device-desktop",
  wifi = "wifi",
  wifiOff = "wifi-off",
  ethernet = "ethernet",
  bt = "bluetooth",
  btOff = "bluetooth-off",
  powerSaver = "leaf",
  powerBalanced = "scale",
  powerPerformance = "bolt",
  themeDark = "moon",
  themeLight = "sun",
  themeAuto = "contrast",
  dnd = "bell-off",
  dndOff = "bell",
  caffeine = "mug",
  nightLight = "moon-stars",
  nightLightOff = "moon-off",
  lock = "lock",
  suspend = "zzz",
  logout = "logout",
  reboot = "refresh",
  shutdown = "power",
}

-- ---------- sliders: audio & brightness ----------

-- kind: "vol" (output) or "mic" (input)
local function volumeTile(kind, title, glyphOn, glyphOff)
  local muted = S[kind .. "Muted"]
  local onChange, onEnd = sys.slider(kind)

  local visualState = "disabled"
  if S.audioReady then
    visualState = muted and "muted" or "active"
  end

  return C.sliderTile({
    key = "t-" .. kind,
    glyph = muted and glyphOff or glyphOn,
    title = title,
    state = visualState,
    value = S[kind],
    enabled = S.audioReady,
    tooltip = tr("core.tip.mute"),
    onClick = function() sys.toggle(kind) end,
    onChange = onChange,
    onEnd = onEnd,
  })
end

local function monitorTiles()
  local tiles = {}

  if #S.monitors == 0 then
    table.insert(tiles, C.sliderTile({
      key = "t-bri-empty",
      glyph = G.bright,
      title = tr("core.brightness"),
      state = "disabled",
      value = 0,
      enabled = false,
    }))
    return tiles
  end

  for _, mon in ipairs(S.monitors) do
    local onChange, onEnd = sys.monitorSlider(mon)

    table.insert(tiles, C.sliderTile({
      key = "t-bri-" .. mon.bus,
      glyph = G.monitor,
      title = mon.name,
      state = mon.ready and "active" or "disabled",
      value = mon.value,
      enabled = mon.ready,
      tooltip = tr("core.tip.brightness_preset"),
      onClick = function() sys.applyBrightnessPreset(mon) end,
      onChange = onChange,
      onEnd = onEnd,
    }))
  end
  return tiles
end

-- ---------- connectivity ----------

local function netTile()
  local n = S.net
  local onCycle = function() sys.cycleNetwork() end

  if n.kind == "ethernet" then
    return C.tile({
      key = "t-net",
      glyph = G.ethernet,
      title = tr("core.ethernet"),
      subtitle = n.name ~= "" and n.name or tr("core.connected"),
      state = "active",
      tooltip = tr("core.tip.network_cycle"),
      onClick = onCycle,
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

-- ---------- quick toggles (4 cols: theme mode, DND, caffeine, nightlight) ----------

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

  return {
    C.actionTile({
      key = "q-theme",
      glyph = themeGlyph,
      label = themeLabel,
      active = S.themeMode ~= "auto",
      tooltip = tr("core.tip.theme_cycle"),
      onClick = function() sys.cycleThemeMode() end,
    }),
    C.actionTile({
      key = "q-dnd",
      glyph = S.dnd and G.dnd or G.dndOff,
      label = tr("core.dnd"),
      active = S.dnd,
      onClick = function() sys.toggle("dnd") end,
    }),
    C.actionTile({
      key = "q-caffeine",
      glyph = G.caffeine,
      label = tr("core.caffeine"),
      active = S.caffeine,
      onClick = function() sys.toggle("caffeine") end,
    }),
    C.actionTile({
      key = "q-nightlight",
      glyph = S.nightLight and G.nightLight or G.nightLightOff,
      label = tr("core.night_light"),
      active = S.nightLight,
      onClick = function() sys.toggle("nightLight") end,
    }),
    cols = 4,
  }
end

-- ---------- session actions (3rd column: lock on top -> shutdown on bottom) ----------

local function sessionColumn()
  if noctalia.getConfig("hide_session_button") == true then
    return nil
  end

  local function sBtn(key, glyph, action, tip)
    return C.iconTile({
      key = key,
      glyph = glyph,
      tooltip = tip,
      active = false,
      onClick = function()
        panel.close()
        noctalia.runAsync({ "noctalia", "msg", "session", action })
      end,
    })
  end

  return ui.column({
    key = "session-col",
    width = 56,
    gap = 10,
    align = "stretch",
  }, {
    sBtn("s-lock", G.lock, "lock", tr("core.session.lock")),
    sBtn("s-suspend", G.suspend, "lock-and-suspend", tr("core.session.suspend_tip")),
    sBtn("s-logout", G.logout, "logout", tr("core.session.logout")),
    sBtn("s-reboot", G.reboot, "reboot", tr("core.session.reboot")),
    sBtn("s-shutdown", G.shutdown, "shutdown", tr("core.session.shutdown")),
  })
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
      close = tr("core.tip.close"),
    },
    onSettings = function() noctalia.openSettings() end,
    onClose = function() panel.close() end,
  })
end

local function render()
  local groups = {
    { volumeTile("vol", tr("core.audio"), G.vol, G.volOff), volumeTile("mic", tr("core.mic"), G.mic, G.micOff) },
  }

  local mons = monitorTiles()
  for i = 1, #mons, 2 do
    table.insert(groups, { mons[i], mons[i + 1] })
  end

  table.insert(groups, { netTile(), btTile() })

  local pRow = powerProfileRow()
  if pRow then
    table.insert(groups, pRow)
  end

  table.insert(groups, quickToggleRow())

  local mainCol = ui.column({ key = "main-col", flexGrow = 1, gap = 10 }, C.grid(groups))
  local bodyItems = { mainCol }

  local sCol = sessionColumn()
  if sCol then
    table.insert(bodyItems, sCol)
  end

  panel.render(ui.column({ gap = 12 }, {
    header(),
    ui.row({ key = "body", gap = 10, align = "stretch" }, bodyItems),
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
