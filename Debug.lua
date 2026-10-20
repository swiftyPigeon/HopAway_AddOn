-- Debug.lua: /hop debug records a timestamped log of layer, zone, group,
-- invite, popup and system-message events, to learn how layering really
-- behaves on this client. The log lives in HopAwayDB.debugLog, so after a
-- /reload or logout it can be read from WTF/Account/<id>/SavedVariables.
local _, ns = ...
local L = ns.Logic
local Debug = {}
ns.Debug = Debug

local MAX_LINES = 500
local SHOW_LINES = 15
local marks = 0
local muted = false -- while printing the log, don't log the printout

local function On()
  return ns.adb and ns.adb.debug and not muted
end

-- Everything ns.Print says is logged too (see Core.lua).
function ns.Log(fmt, ...)
  if not On() then return end
  local msg = L.StripColors(select("#", ...) > 0 and fmt:format(...) or fmt)
  L.LogPush(ns.adb.debugLog, ("%s %8.1f  %s"):format(date("%H:%M:%S"), GetTime(), msg), MAX_LINES)
end

local function GroupLine()
  if not IsInGroup() then return "solo" end
  local leader = UnitIsGroupLeader("player") and "me"
  for i = 1, GetNumGroupMembers() - 1 do
    if not leader and UnitIsGroupLeader("party" .. i) then leader = UnitName("party" .. i) end
  end
  return ("%s of %d, leader %s"):format(IsInRaid() and "raid" or "party", GetNumGroupMembers(), leader or "?")
end

-- Where we are right now, one line.
local function Snapshot(why)
  ns.Log("%s: zone %s (%s), layer #%s, %s", why, tostring(ns.Layers.GetMapName()),
    tostring(ns.Layers.GetMap()), tostring(ns.Layers.GetLayer()), GroupLine())
end

function Debug.Mark()
  if not On() then ns.Print("Debug log is off. Type /hop debug on first."); return end
  marks = marks + 1
  Snapshot("MARK " .. marks)
  ns.Print("Mark %d logged.", marks)
end

function Debug.Command(arg)
  if arg == "on" then
    ns.adb.debug = true
    ns.Print("Debug log on. Use /hop mark before and after each test step.")
    Snapshot("debug on")
  elseif arg == "off" then
    Snapshot("debug off")
    ns.adb.debug = false
    ns.Print("Debug log off (%d lines kept).", #ns.adb.debugLog)
  elseif arg == "clear" then
    wipe(ns.adb.debugLog)
    marks = 0
    ns.Print("Debug log cleared.")
  else
    local log = ns.adb.debugLog
    muted = true
    ns.Print("Debug log is %s, %d lines. It's saved to SavedVariables\\HopAway.lua " ..
      "on /reload or logout. Last lines:", ns.adb.debug and "on" or "off", #log)
    for i = math.max(1, #log - SHOW_LINES + 1), #log do ns.Print("  %s", log[i]) end
    muted = false
  end
end

---------------------------------------------------------------------------
-- What gets recorded (layer and zone changes are logged from Layers.lua)
---------------------------------------------------------------------------

local lastGroup
ns.On("GROUP_ROSTER_UPDATE", function()
  local line = GroupLine()
  if line ~= lastGroup then
    lastGroup = line
    Snapshot("group changed")
  end
end)
ns.On("GROUP_JOINED", function() ns.Log("event GROUP_JOINED") end)
ns.On("GROUP_LEFT", function() ns.Log("event GROUP_LEFT") end)
ns.On("PARTY_INVITE_REQUEST", function(name) ns.Log("invite from %s", tostring(name)) end)
ns.On("PLAYER_ENTERING_WORLD", function(login, reload)
  ns.Log("entering world (login %s, reload %s)", tostring(login), tostring(reload))
end)
-- "X joins the party", "You leave the group", "Your group has been
-- disbanded" and, we hope, whatever the game says about world refreshes.
ns.On("CHAT_MSG_SYSTEM", function(text) ns.Log("system: %s", tostring(text)) end)

-- Every popup the game shows, by name, so we learn what the world-refresh
-- prompt is called. hooksecurefunc only watches; it doesn't taint.
pcall(hooksecurefunc, "StaticPopup_Show", function(which)
  ns.Log("popup shown: %s", tostring(which))
end)
