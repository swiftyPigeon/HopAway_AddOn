-- Setup.lua: start settings and the welcome. On PvE realms everything starts
-- on; on PvP realms (or while we don't know the realm type yet) everything
-- starts off and the player has to turn it on, because sharing shows your
-- name, zone and layer to anyone who joins the HopAway channel.
local _, ns = ...
local L = ns.Logic
local Setup = {}
ns.Setup = Setup

local WELCOME_DELAY = 10 -- after login, once the chat and channel are settled
local ZONE_DELAY = 3     -- zone PvP info can lag behind the zone change
local PVE_ZONES = 2      -- outdoor zones without a PvP type before we say PvE

local pveZones = {} -- [mapID] = true, this session only

-- "pvp", "pve" or nil; remembered per realm for all characters.
function Setup.RealmType()
  return ns.adb and ns.realm and ns.adb.realms[ns.realm]
end

local function ApplyStart(realmType)
  for k, v in pairs(L.StartSettings(realmType)) do ns.db[k] = v end
  ns.Layers.RequestAnnounce()
  ns.UI.Refresh()
end

local function WelcomeOn()
  ns.db.welcomed = true
  ns.Print("Welcome! HopAway is on: it shares your layer with other HopAway users, " ..
    "invites players who ask to join your layer, and accepts the invite from the helper you ask. " ..
    "/hop off turns it all off; /hop show lets you pick what stays on.")
end

local function ShowWelcomePopup()
  StaticPopup_Show(Setup.RealmType() == "pvp" and "HOPAWAY_WELCOME_PVP" or "HOPAWAY_WELCOME")
end

-- The player answered the welcome popup (any way of closing it counts).
local function Answered(on)
  if ns.db.chosen then return end
  ns.SetAll(on)
  if not on then ns.Print("You can turn it on any time with /hop on.") end
end

local PRIVACY = "Anyone who joins the HopAway channel can see the name, zone and layer of " ..
  "players who share their layer."

StaticPopupDialogs.HOPAWAY_WELCOME_PVP = {
  text = "Welcome to HopAway.\n\nThis is a PvP realm, so HopAway starts off. " .. PRIVACY ..
    " Enemy players could use that to find you.\n\nTurn on sharing and layer help?",
  button1 = "Turn on",
  button2 = "Keep off",
  OnAccept = function() ns.Safe(Answered, true) end,
  OnCancel = function() ns.Safe(Answered, false) end,
  OnHide = function() ns.Safe(Answered, false) end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

StaticPopupDialogs.HOPAWAY_WELCOME = {
  text = "Welcome to HopAway.\n\nTurn on sharing and layer help? Hopping only works when " ..
    "players on other layers have it on.\n\nOn a PvP realm, keep it off unless you're fine with this: " ..
    PRIVACY,
  button1 = "Turn on",
  button2 = "Keep off",
  OnAccept = function() ns.Safe(Answered, true) end,
  OnCancel = function() ns.Safe(Answered, false) end,
  OnHide = function() ns.Safe(Answered, false) end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

-- We just learned the realm type. Characters that never chose their own
-- settings get the start settings for it.
local function Learned(realmType)
  if ns.adb.realms[ns.realm] == realmType then return end
  ns.adb.realms[ns.realm] = realmType
  if ns.db.chosen or StaticPopup_Visible("HOPAWAY_WELCOME") then return end
  local wasOn = ns.db.share
  ApplyStart(realmType)
  if realmType == "pve" then
    WelcomeOn()
  else
    if wasOn then ns.Print("This is a PvP realm, so HopAway turned itself off.") end
    ShowWelcomePopup()
  end
end

local function CheckZone()
  if not ns.realm or Setup.RealmType() == "pvp" then return end
  local get = (C_PvP and C_PvP.GetZonePVPInfo) or GetZonePVPInfo
  if not get then return end
  local evidence = L.ZoneRealmEvidence((get()), IsInInstance())
  if evidence == "pvp" then
    Learned("pvp")
  elseif evidence == "pve" and not Setup.RealmType() then
    -- Only "contested" is proof; a missing PvP type could be a glitch, so
    -- wait until several zones agree.
    local map = C_Map.GetBestMapForUnit("player")
    if map then pveZones[map] = true end
    local n = 0
    for _ in pairs(pveZones) do n = n + 1 end
    if n >= PVE_ZONES then Learned("pve") end
  end
end

ns.On("PLAYER_ENTERING_WORLD", function() ns.After(ZONE_DELAY, CheckZone) end)
ns.On("ZONE_CHANGED_NEW_AREA", function() ns.After(ZONE_DELAY, CheckZone) end)

local function Welcome()
  if ns.db.chosen then return end
  if Setup.RealmType() == "pve" then
    if not ns.db.welcomed then WelcomeOn() end
  else
    ShowWelcomePopup()
  end
end

-- Called at PLAYER_LOGIN, before the channel is joined.
function Setup.Init()
  if not ns.db.chosen then ApplyStart(Setup.RealmType()) end
  ns.After(WELCOME_DELAY, Welcome)
end
