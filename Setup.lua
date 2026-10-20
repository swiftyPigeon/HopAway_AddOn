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

-- "pvp", "pve" or nil. A contested zone (remembered per realm for all
-- characters) proves PvP; otherwise the realm name may say. Nothing else
-- counts as proof of PvE.
function Setup.RealmType()
  if not (ns.adb and ns.realm) then return nil end
  return ns.adb.realms[ns.realm] or L.RealmNameHint(ns.realm)
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
  local before = Setup.RealmType()
  ns.adb.realms[ns.realm] = realmType
  if before == realmType then return end -- the realm name already said so
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
  if L.ZoneRealmEvidence((get()), IsInInstance()) == "pvp" then Learned("pvp") end
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
  -- 0.3.0 and older stored "pve" for realms whose zones had no PvP type,
  -- which happens on PvP realms too. Forget those guesses once.
  if not ns.adb.realmsFixed then
    for realm, t in pairs(ns.adb.realms) do
      if t == "pve" then ns.adb.realms[realm] = nil end
    end
    ns.adb.realmsFixed = true
  end
  if not ns.db.chosen then
    local wasOn = ns.db.share
    local realmType = Setup.RealmType()
    ApplyStart(realmType)
    if wasOn and not ns.db.share then
      ns.Print(realmType == "pvp" and "This is a PvP realm, so HopAway turned itself off." or
        "HopAway can't tell whether this realm is PvE or PvP, so it turned itself off until you choose.")
    end
  end
  ns.After(WELCOME_DELAY, Welcome)
end
