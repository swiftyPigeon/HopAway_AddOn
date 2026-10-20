-- Layers.lua: work out which layer we are on (from NPC GUIDs), announce it
-- on the hidden channel, and remember what other HopAway users announced.
local _, ns = ...
local L = ns.Logic
local Layers = {}
ns.Layers = Layers

local ANNOUNCE_EVERY = 600 -- re-announce every 10 min...
local ANNOUNCE_JITTER = 120 -- ...plus up to 2 min, so users drift apart
local ANNOUNCE_GAP = 30    -- never announce more often than this
local SETTLE_MIN, SETTLE_MAX = 5, 15 -- wait this long after a change before announcing
local CROWD_GAP = 120      -- a big swing in the crowd sample re-announces at most this often
local PEER_MAX_AGE = 1500  -- forget a peer after ~2 announce periods
local JOIN_DELAY = 8       -- let General/Trade take their channel numbers first
local SEEN_WINDOW = 300    -- crowd sample: players noticed in the last 5 min
local LEFT_TIME = 2700     -- remember layers we hopped away from for 45 min

local detector = L.NewDetector({ need = 2, quiet = 3, window = 60 })
local peers = {}
local mapID, mapName
local dirty, sendAt = false, 0
local lastSent, lastSeenSent, lastAnnounce, nextPeriodic = nil, nil, -math.huge, math.huge
local seenPlayers = L.NewSeen(SEEN_WINDOW)
local left = {} -- [mapID] = { [uid] = time we hopped away from it }, this session only
local myGUID

-- Something we announce changed. Wait a random few seconds first: users who
-- change at the same moment don't all send at once, and a quick flip-flop
-- (a helper's guest joining and leaving) is never sent at all.
local function MarkDirty()
  if not dirty then dirty, sendAt = true, GetTime() + math.random(SETTLE_MIN, SETTLE_MAX) end
end

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
  -- Players seen before belong to the old layer. (On the first reading in
  -- a zone, old is nil and what we saw is this layer's.)
  if old then L.SeenReset(seenPlayers) end
  MarkDirty()
  ns.Hop.OnLayerChanged(new, old)
  ns.UI.Refresh()
end

local function UpdateMap()
  local id, name = CurrentZoneMap()
  if id ~= mapID then
    mapID, mapName = id, name
    detector:Reset()
    L.SeenReset(seenPlayers)
    ns.UI.Refresh()
  end
end

local function NotePlayer(guid)
  if mapID and guid ~= myGUID and L.IsPlayerGUID(guid) then
    L.SeenAdd(seenPlayers, guid, GetTime())
  end
end

local function Observe(unit)
  if not mapID or not UnitExists(unit) then return end
  if UnitIsPlayer(unit) then return NotePlayer(UnitGUID(unit)) end
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
-- No combat log: this client forbids addons from registering
-- COMBAT_LOG_EVENT_UNFILTERED (it pops up a "blocked" warning), so players
-- are only counted from nameplates, target and mouseover.

function Layers.SeenCount()
  return math.min(L.SeenCount(seenPlayers, GetTime()), L.MAX_SEEN)
end

-- A hop moved us away from `uid`: pick it less for a while.
function Layers.MarkLeft(uid)
  if not mapID or not uid then return end
  left[mapID] = left[mapID] or {}
  left[mapID][uid] = GetTime()
end

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

Layers.RequestAnnounce = MarkDirty

-- Helpers in a group players made don't take guests (see CanHelp in
-- Hop.lua), so they announce themselves as not helping until they're solo
-- or back in a HopAway-only group.
function Layers.Helping()
  return ns.db.help and (not IsInGroup() or ns.Hop.HopAwayGroup())
end

-- Re-announce when that flips: on roster changes, and from the 1 s tick
-- because a guest who stays turns into a real groupmate without an event.
local wasHelping
local function CheckHelping()
  local helping = Layers.Helping()
  if helping == wasHelping then return end
  wasHelping = helping
  MarkDirty()
  ns.UI.Refresh()
end
ns.On("GROUP_ROSTER_UPDATE", CheckHelping)

local function MaybeAnnounce(now)
  if not ns.db.share then return end
  local uid = Layers.GetLayer()
  if not uid or not ns.ChannelId() then return end
  local seen = Layers.SeenCount()
  local periodic = now >= nextPeriodic
  -- A big swing in the crowd sample is worth an update, but not often.
  local crowdMoved = L.CrowdChanged(lastSeenSent, seen) and now - lastAnnounce >= CROWD_GAP
  if not periodic and not crowdMoved and (not dirty or now < sendAt) then return end
  if now - lastAnnounce < ANNOUNCE_GAP then return end
  dirty = false
  local help = Layers.Helping()
  local state = mapID .. ":" .. uid .. ":" .. (help and 1 or 0)
  if state == lastSent and not periodic and not crowdMoved then return end -- changed back while settling
  ns.Send("A", { map = mapID, uid = uid, help = help, seen = seen }, "CHANNEL", nil, "announce")
  lastSent, lastSeenSent, lastAnnounce = state, seen, now
  nextPeriodic = now + ANNOUNCE_EVERY + math.random(0, ANNOUNCE_JITTER)
end

ns.OnMessage("A", function(msg, sender)
  L.UpdatePeer(peers, sender, msg.map, msg.uid, msg.help, GetTime(), msg.seen)
  if msg.map == mapID then ns.UI.Refresh() end
end)

-- Known layers in my zone (HopAway users only), including me. Layers we
-- hopped away from recently get leftAgo (seconds).
function Layers.KnownLayers()
  if not mapID then return {} end
  local now = GetTime()
  local uid = Layers.GetLayer()
  local me = uid and { uid = uid, help = ns.db.share and Layers.Helping(), seen = Layers.SeenCount() }
  local list = L.LayersInMap(peers, mapID, now, PEER_MAX_AGE, me)
  local leftHere = left[mapID]
  for _, layer in ipairs(list) do
    local t = leftHere and leftHere[layer.uid]
    if t and now - t < LEFT_TIME then layer.leftAgo = now - t end
  end
  return list
end

-- HopAway users announced on my layer: no point asking them by hand.
function Layers.PeersOnMyLayer()
  local out, uid = {}, Layers.GetLayer()
  for name, p in pairs(peers) do
    if p.map == mapID and p.uid == uid then out[name] = true end
  end
  return out
end

function Layers.HelpersOn(uid)
  for _, layer in ipairs(Layers.KnownLayers()) do
    if layer.uid == uid then return layer.helpers end
  end
  return 0
end

function Layers.Init()
  myGUID = UnitGUID("player")
  ns.After(JOIN_DELAY, JoinChannel)
  ns.Every(1, function()
    local now = GetTime()
    UpdateMap()
    local new, old = detector:Evaluate(now)
    if new then LayerChanged(new, old) end
    CheckHelping()
    MaybeAnnounce(now)
  end)
  ns.Every(60, function()
    L.ExpirePeers(peers, GetTime(), PEER_MAX_AGE)
    if not ns.ChannelId() then JoinChannel() end
    ns.UI.Refresh()
  end)
end
