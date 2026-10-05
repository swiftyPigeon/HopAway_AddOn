-- Logic.lua: pure functions with no WoW API calls, so tests/test_logic.lua can
-- run them with plain `lua`. In game they live on ns.Logic.
local _, ns = ...
ns = ns or {}
local L = {}
ns.Logic = L

---------------------------------------------------------------------------
-- NPC GUIDs: Creature-0-<server>-<instance>-<zoneUID>-<npcID>-<spawnUID>
---------------------------------------------------------------------------

-- Returns zoneUID (string) and a key identifying this NPC spawn, or nil for
-- players, pets, objects and anything else that isn't a Creature/Vehicle.
function L.ParseGUID(guid)
  if type(guid) ~= "string" then return nil end
  local kind, zoneUID, npcID, spawnUID =
    guid:match("^(%a+)%-%d+%-%d+%-%d+%-(%d+)%-(%d+)%-(%x+)$")
  if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
  return zoneUID, npcID .. "-" .. spawnUID
end

---------------------------------------------------------------------------
-- Layer detector: zoneUID readings are noisy (border creatures, other
-- shards), so a new zoneUID is only accepted once `need` different NPCs
-- showed it and the current one hasn't been seen for `quiet` seconds.
---------------------------------------------------------------------------

local Detector = {}
Detector.__index = Detector

function L.NewDetector(opts)
  opts = opts or {}
  return setmetatable({
    need = opts.need or 2, quiet = opts.quiet or 3, window = opts.window or 60,
    current = nil, seen = {}, -- seen[uid] = { last = t, npcs = { [npcKey] = t } }
  }, Detector)
end

function Detector:Reset()
  self.current, self.seen = nil, {}
end

-- Record one NPC sighting. Returns newUID, oldUID when the layer changed.
function Detector:Observe(uid, npcKey, now)
  local s = self.seen[uid]
  if not s then s = { npcs = {} }; self.seen[uid] = s end
  s.last, s.npcs[npcKey] = now, now
  return self:Evaluate(now)
end

-- Call this periodically too: the quiet period can end without new sightings.
function Detector:Evaluate(now)
  for uid, s in pairs(self.seen) do
    for key, t in pairs(s.npcs) do
      if now - t > self.window then s.npcs[key] = nil end
    end
    if uid ~= self.current and now - s.last > self.window then self.seen[uid] = nil end
  end

  local cur = self.current and self.seen[self.current]
  if cur and now - cur.last < self.quiet then return nil end

  local best, bestN, bestLast
  for uid, s in pairs(self.seen) do
    if uid ~= self.current then
      local n = 0
      for _ in pairs(s.npcs) do n = n + 1 end
      if n >= self.need and (not best or n > bestN or (n == bestN and s.last > bestLast)) then
        best, bestN, bestLast = uid, n, s.last
      end
    end
  end
  if not best then return nil end

  local old = self.current
  self.current = best
  -- Forget other readings so a stale old layer can't flip us back.
  self.seen = { [best] = self.seen[best] }
  return best, old
end

---------------------------------------------------------------------------
-- Messages: "<kind>:<version>:<fields...>" (":" because "|" is WoW's chat
-- escape character). Field types: n = number, d = digit string,
-- b = boolean (1/0), s = short alphanumeric word.
---------------------------------------------------------------------------

L.VERSION = "1"
L.SEP = ":"

L.SPEC = {
  A = { { "map", "n" }, { "uid", "d" }, { "help", "b" } },         -- announce my layer
  Q = { { "map", "n" }, { "uid", "d" }, { "nonce", "s" } },        -- ask for an invite
  O = { { "nonce", "s" }, { "inGroup", "b" }, { "recent", "n" } }, -- helper offer
  R = { { "nonce", "s" } },                                        -- please invite me
  D = { { "nonce", "s" }, { "reason", "s" } },                     -- declined
  I = { { "nonce", "s" } },                                        -- invite sent
}

local function EncodeField(ftype, v)
  if ftype == "n" then
    v = tonumber(v)
    if not v or v < 0 or v ~= math.floor(v) then return nil end
    return string.format("%d", v)
  elseif ftype == "d" then
    v = tostring(v)
    return v:match("^%d+$") and v or nil
  elseif ftype == "b" then
    return v and "1" or "0"
  elseif ftype == "s" then
    v = tostring(v)
    return (v:match("^%w+$") and #v <= 16) and v or nil
  end
end

local function DecodeField(ftype, s)
  if ftype == "n" then
    return s:match("^%d+$") and tonumber(s) or nil
  elseif ftype == "d" then
    return s:match("^%d+$") and s or nil
  elseif ftype == "b" then
    if s == "1" then return true elseif s == "0" then return false end
    return nil
  elseif ftype == "s" then
    return (s:match("^%w+$") and #s <= 16) and s or nil
  end
end

-- Encode(kind, fieldsTable) -> string, or nil if any field is invalid.
function L.Encode(kind, fields)
  local spec = L.SPEC[kind]
  if not spec then return nil end
  local parts = { kind, L.VERSION }
  for _, f in ipairs(spec) do
    local v = EncodeField(f[2], fields[f[1]])
    if v == nil then return nil end
    parts[#parts + 1] = v
  end
  local text = table.concat(parts, L.SEP)
  if #text > 250 then return nil end
  return text
end

-- Decode(text) -> { kind = "A", map = ..., ... } or nil.
function L.Decode(text)
  if type(text) ~= "string" or #text > 250 then return nil end
  local parts = {}
  for part in (text .. L.SEP):gmatch("([^" .. L.SEP .. "]*)" .. L.SEP) do
    parts[#parts + 1] = part
  end
  local kind, version = parts[1], parts[2]
  local spec = L.SPEC[kind]
  if not spec or version ~= L.VERSION or #parts ~= #spec + 2 then return nil end
  local msg = { kind = kind }
  for i, f in ipairs(spec) do
    local v = DecodeField(f[2], parts[i + 2])
    if v == nil then return nil end
    msg[f[1]] = v
  end
  return msg
end

-- Short random id tying offers/requests to one ask.
function L.Nonce(rng)
  local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  local out = {}
  for i = 1, 6 do
    local k = math.floor(rng() * #chars) + 1
    out[i] = chars:sub(k, k)
  end
  return table.concat(out)
end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------

-- "Name" -> "Name-Realm"; names that already carry a realm are kept.
function L.FullName(name, realm)
  if not name or name == "" then return nil end
  name = name:gsub("%s", "")
  if name:find("-", 1, true) then return name end
  if realm and realm ~= "" then return name .. "-" .. realm:gsub("%s", "") end
  return name
end

---------------------------------------------------------------------------
-- Peers and layers
---------------------------------------------------------------------------

function L.UpdatePeer(peers, name, map, uid, help, now)
  peers[name] = { map = map, uid = uid, help = help and true or false, t = now }
end

function L.ExpirePeers(peers, now, maxAge)
  for name, p in pairs(peers) do
    if now - p.t > maxAge then peers[name] = nil end
  end
end

-- Layers known in one zone, sorted by zoneUID. `me` = { uid, help } adds
-- the player. Each entry: { uid, users, helpers, mine, newest }.
function L.LayersInMap(peers, mapID, now, maxAge, me)
  local byUid, list = {}, {}
  local function add(uid, help, isMe, t)
    local layer = byUid[uid]
    if not layer then
      layer = { uid = uid, users = 0, helpers = 0, mine = false, newest = 0 }
      byUid[uid] = layer
      list[#list + 1] = layer
    end
    layer.users = layer.users + 1
    if help then layer.helpers = layer.helpers + 1 end
    if isMe then layer.mine = true end
    if t > layer.newest then layer.newest = t end
  end
  for _, p in pairs(peers) do
    if p.map == mapID and now - p.t <= maxAge then add(p.uid, p.help, false, p.t) end
  end
  if me and me.uid then add(me.uid, me.help, true, now) end
  table.sort(list, function(a, b)
    local x, y = tonumber(a.uid), tonumber(b.uid)
    if x and y and x ~= y then return x < y end
    return a.uid < b.uid
  end)
  return list
end

-- Random pick weighted by weight(item); nil if every weight is 0.
function L.WeightedPick(items, weight, rng)
  local total = 0
  for _, it in ipairs(items) do total = total + weight(it) end
  if total <= 0 then return nil end
  local r = rng() * total
  local last
  for _, it in ipairs(items) do
    local w = weight(it)
    if w > 0 then
      last = it
      r = r - w
      if r < 0 then return it end
    end
  end
  return last -- float rounding
end

-- Pick another layer that has at least one helper, weighted by helper count.
-- This is a guess: we can't see how many real players are on any layer.
function L.PickLayer(layers, myUid, rng)
  local layer = L.WeightedPick(layers, function(l)
    if l.uid == myUid then return 0 end
    return l.helpers
  end, rng)
  return layer and layer.uid
end

-- Chance that one helper answers an ask, aiming for ~target offers in total.
function L.ReplyChance(helpers, target)
  if helpers <= 0 then return 1 end
  return math.min(1, target / helpers)
end

-- Offers: { name, inGroup, recent }. Favour helpers not in a group and with
-- fewer recent invites; skip names in `tried`.
function L.PickOffer(offers, tried, rng)
  return L.WeightedPick(offers, function(o)
    if tried[o.name] then return 0 end
    return (o.inGroup and 1 or 3) / (1 + (o.recent or 0))
  end, rng)
end

-- Seconds to wait before asking again after `failures` failed asks.
L.BACKOFF = { 20, 60, 180 }
function L.Backoff(failures)
  if failures <= 0 then return 0 end
  return L.BACKOFF[math.min(failures, #L.BACKOFF)]
end

---------------------------------------------------------------------------
-- Throttles
---------------------------------------------------------------------------

-- Token bucket: `cap` messages in a burst, refilled at `rate` per second.
function L.NewBucket(cap, rate, now)
  return { tokens = cap, cap = cap, rate = rate, t = now or 0 }
end

function L.BucketTake(b, now)
  b.tokens = math.min(b.cap, b.tokens + (now - b.t) * b.rate)
  b.t = now
  if b.tokens >= 1 then
    b.tokens = b.tokens - 1
    return true
  end
  return false
end

-- At most one event per key per `interval` seconds.
function L.NewKeyed(interval)
  return { interval = interval, last = {} }
end

function L.KeyedAllow(k, key, now)
  for other, t in pairs(k.last) do
    if now - t >= k.interval then k.last[other] = nil end
  end
  if k.last[key] then return false end
  k.last[key] = now
  return true
end

return L
