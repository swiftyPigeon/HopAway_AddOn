-- Layers.lua: work out which layer we are on (from NPC GUIDs), announce it
-- on the hidden channel, and remember what other HopAway users announced.
local _, ns = ...
local L = ns.Logic
local Layers = {}
ns.Layers = Layers

local ANNOUNCE_EVERY = 600 -- re-announce every 10 min (plus up to 60 s jitter)
local ANNOUNCE_GAP = 15    -- never announce more often than this
local PEER_MAX_AGE = 1500  -- forget a peer after ~2.5 announce periods
local JOIN_DELAY = 8       -- let General/Trade take their channel numbers first

local detector = L.NewDetector({ need = 2, quiet = 3, window = 60 })
local peers = {}
local mapID, mapName
local dirty, lastAnnounce, nextPeriodic = false, -math.huge, 0

---------------------------------------------------------------------------
-- Zone and layer
---------------------------------------------------------------------------

local ZONE = 3 -- Enum.UIMapType.Zone; Cosmic/World/Continent are below it

-- The zone map we're in (walking up from caves/micro maps), or nil in
-- instances and on anything that isn't a zone.
local function CurrentZoneMap()
  if IsInInstance() then return nil end
  local id = C_Map.GetBestMapForUnit("player")
  for _ = 1, 5 do
    local info = id and C_Map.GetMapInfo(id)
    if not info or info.mapType < ZONE then return nil end
    if info.mapType == ZONE then return id, info.name end
    id = info.parentMapID
  end
end

function Layers.GetMap() return mapID end
function Layers.GetMapName() return mapName end
function Layers.GetLayer() return mapID and detector.current end

local function LayerChanged(new, old)
  dirty = true
  ns.Hop.OnLayerChanged(new, old)
  ns.UI.Refresh()
end

local function UpdateMap()
  local id, name = CurrentZoneMap()
  if id ~= mapID then
    mapID, mapName = id, name
    detector:Reset()
    ns.UI.Refresh()
  end
end

local function Observe(unit)
  if not mapID or not UnitExists(unit) or UnitIsPlayer(unit) then return end
  local uid, npc = L.ParseGUID(UnitGUID(unit))
  if not uid then return end
  local new, old = detector:Observe(uid, npc, GetTime())
  if new then LayerChanged(new, old) end
end

ns.On("PLAYER_ENTERING_WORLD", UpdateMap)
ns.On("ZONE_CHANGED_NEW_AREA", UpdateMap)
ns.On("PLAYER_TARGET_CHANGED", function() Observe("target") end)
ns.On("UPDATE_MOUSEOVER_UNIT", function() Observe("mouseover") end)
ns.On("NAME_PLATE_UNIT_ADDED", Observe)

---------------------------------------------------------------------------
-- Hidden channel
---------------------------------------------------------------------------

local function HideChannel()
  if not ChatFrame_RemoveChannel then return end
  for i = 1, NUM_CHAT_WINDOWS or 10 do
    local frame = _G["ChatFrame" .. i]
    if frame then ChatFrame_RemoveChannel(frame, ns.CHANNEL) end
  end
end

local function JoinChannel()
  if not ns.ChannelId() then JoinTemporaryChannel(ns.CHANNEL) end
  ns.After(2, HideChannel)
end

function Layers.ChannelReady()
  return ns.ChannelId() ~= nil
end

-- arg 9 is the channel's base name
ns.On("CHAT_MSG_CHANNEL_NOTICE", function(_, _, _, _, _, _, _, _, name)
  if name == ns.CHANNEL then HideChannel() end
end)

---------------------------------------------------------------------------
-- Announcements
---------------------------------------------------------------------------

function Layers.RequestAnnounce()
  dirty = true
end

local function MaybeAnnounce(now)
  if not ns.db.share then return end
  local uid = Layers.GetLayer()
  if not uid or not ns.ChannelId() then return end
  if now >= nextPeriodic then dirty = true end
  if not dirty or now - lastAnnounce < ANNOUNCE_GAP then return end
  ns.Send("A", { map = mapID, uid = uid, help = ns.db.help }, "CHANNEL", nil, "announce")
  dirty, lastAnnounce = false, now
  nextPeriodic = now + ANNOUNCE_EVERY + math.random(0, 60)
end

ns.OnMessage("A", function(msg, sender)
  L.UpdatePeer(peers, sender, msg.map, msg.uid, msg.help, GetTime())
  if msg.map == mapID then ns.UI.Refresh() end
end)

-- Known layers in my zone (HopAway users only), including me.
function Layers.KnownLayers()
  if not mapID then return {} end
  local uid = Layers.GetLayer()
  local me = uid and { uid = uid, help = ns.db.share and ns.db.help }
  return L.LayersInMap(peers, mapID, GetTime(), PEER_MAX_AGE, me)
end

function Layers.HelpersOn(uid)
  for _, layer in ipairs(Layers.KnownLayers()) do
    if layer.uid == uid then return layer.helpers end
  end
  return 0
end

function Layers.Init()
  ns.After(JOIN_DELAY, JoinChannel)
  ns.Every(1, function()
    local now = GetTime()
    UpdateMap()
    local new, old = detector:Evaluate(now)
    if new then LayerChanged(new, old) end
    MaybeAnnounce(now)
  end)
  ns.Every(60, function()
    L.ExpirePeers(peers, GetTime(), PEER_MAX_AGE)
    if not ns.ChannelId() then JoinChannel() end
    ns.UI.Refresh()
  end)
end
