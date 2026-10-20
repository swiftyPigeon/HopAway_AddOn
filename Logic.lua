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
-- b = boolean (1/0), s = short alphanumeric word. Readers ignore extra
-- fields at the end, so a later version can add fields without bumping
-- VERSION (0.3.0 bumped it to 2 for the crowd sample in A).
---------------------------------------------------------------------------

L.VERSION = "2"
L.SEP = ":"
L.MAX_SEEN = 999

L.SPEC = {
  A = { { "map", "n" }, { "uid", "d" }, { "help", "b" }, { "seen", "n" } }, -- announce my layer
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
  if not spec or version ~= L.VERSION or #parts < #spec + 2 then return nil end
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

-- `seen` is the peer's crowd sample: players they noticed on their layer.
function L.UpdatePeer(peers, name, map, uid, help, now, seen)
  peers[name] = { map = map, uid = uid, help = help and true or false, t = now, seen = seen }
end

function L.ExpirePeers(peers, now, maxAge)
  for name, p in pairs(peers) do
    if now - p.t > maxAge then peers[name] = nil end
  end
end

-- Middle value (rounded down), or nil for an empty list.
function L.Median(values)
  if #values == 0 then return nil end
  local s = {}
  for i, v in ipairs(values) do s[i] = v end
  table.sort(s)
  local mid = math.floor(#s / 2)
  if #s % 2 == 1 then return s[mid + 1] end
  return math.floor((s[mid] + s[mid + 1]) / 2)
end

-- Layers known in one zone, sorted by zoneUID. `me` = { uid, help, seen }
-- adds the player. Each entry: { uid, users, helpers, mine, newest, crowd }.
-- crowd is the median of the users' crowd samples (users near each other
-- see the same players, so adding them up would count people twice), or
-- nil when nobody on the layer sent one.
function L.LayersInMap(peers, mapID, now, maxAge, me)
  local byUid, list = {}, {}
  local function add(uid, help, isMe, t, seen)
    local layer = byUid[uid]
    if not layer then
      layer = { uid = uid, users = 0, helpers = 0, mine = false, newest = 0, samples = {} }
      byUid[uid] = layer
      list[#list + 1] = layer
    end
    layer.users = layer.users + 1
    if help then layer.helpers = layer.helpers + 1 end
    if isMe then layer.mine = true end
    if t > layer.newest then layer.newest = t end
    if seen then table.insert(layer.samples, seen) end
  end
  for _, p in pairs(peers) do
    if p.map == mapID and now - p.t <= maxAge then add(p.uid, p.help, false, p.t, p.seen) end
  end
  if me and me.uid then add(me.uid, me.help, true, now, me.seen) end
  for _, layer in ipairs(list) do
    layer.crowd, layer.samples = L.Median(layer.samples), nil
  end
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

-- How likely we are to pick a layer. The goal is less competition for mobs.
--   useCrowd: weigh by the crowd sample (players HopAway users noticed):
--     1/(crowd+5)^1.5, softer than below because one user's sample is noisy
--     (5 vs 20 seen = 4:1, 10 vs 20 = 2.2:1).
--   otherwise: weigh by known HopAway users, 1/users² (1 vs 2 = 4:1), a
--     hint that fewer players are there too.
-- Extra helpers add a small bonus (+25% each, at most +50%) so askers spread
-- over layers that can take them, but crowd size stays what matters. A
-- layer we hopped away from recently (leftAgo set) counts a quarter, so we
-- don't land back on it unless it's the only choice.
L.HELPER_BONUS, L.MAX_HELPER_BONUS = 0.25, 1.5
L.CROWD_SMOOTH, L.CROWD_POWER = 5, 1.5
L.LEFT_PENALTY = 0.25
function L.LayerWeight(l, useCrowd)
  if (l.helpers or 0) <= 0 then return 0 end
  local bonus = math.min(1 + L.HELPER_BONUS * (l.helpers - 1), L.MAX_HELPER_BONUS)
  local crowd
  if useCrowd then
    crowd = (l.crowd + L.CROWD_SMOOTH) ^ L.CROWD_POWER
  else
    local users = math.max(l.users or 1, 1)
    crowd = users * users
  end
  local w = bonus / crowd
  if l.leftAgo then w = w * L.LEFT_PENALTY end
  return w
end

-- Pick another layer that has at least one helper. Crowd samples are used
-- only when every candidate has one, so all layers are weighed the same
-- way. It stays random so askers don't all pile onto the same quiet layer.
function L.PickLayer(layers, myUid, rng)
  local useCrowd = true
  for _, l in ipairs(layers) do
    if l.uid ~= myUid and (l.helpers or 0) > 0 and not l.crowd then useCrowd = false end
  end
  local layer = L.WeightedPick(layers, function(l)
    if l.uid == myUid then return 0 end
    return L.LayerWeight(l, useCrowd)
  end, rng)
  return layer and layer.uid
end

---------------------------------------------------------------------------
-- Crowd sample: distinct players noticed on our layer in the last few
-- minutes (nameplates, target, mouseover).
---------------------------------------------------------------------------

function L.IsPlayerGUID(guid)
  return type(guid) == "string" and guid:sub(1, 7) == "Player-"
end

function L.NewSeen(window)
  return { window = window, t = {} }
end

function L.SeenAdd(s, key, now)
  s.t[key] = now
end

function L.SeenReset(s)
  s.t = {}
end

function L.SeenCount(s, now)
  local n = 0
  for k, t in pairs(s.t) do
    if now - t > s.window then s.t[k] = nil else n = n + 1 end
  end
  return n
end

-- Is the change from the last sent sample big enough to announce?
function L.CrowdChanged(old, new)
  if not old then return false end
  return math.abs(new - old) >= math.max(5, old * 0.5)
end

---------------------------------------------------------------------------
-- Fallback contacts: friends and guildmates in our zone we could ask for
-- an invite by hand. The game tells us their zone, not their layer.
---------------------------------------------------------------------------

-- list: { { name, zone, online, kind } } with full names. Skips me,
-- duplicates (a friend who's also in the guild) and names in `skip`.
function L.ZoneContacts(list, zone, me, skip, max)
  local out, seen = {}, {}
  for _, c in ipairs(list) do
    if #out >= max then break end
    local name = c.name
    if c.online and name and c.zone == zone and name ~= me and not seen[name] and not skip[name] then
      seen[name] = true
      out[#out + 1] = { name = name, kind = c.kind }
    end
  end
  return out
end

-- Chance that one helper answers an ask, aiming for ~target offers in total.
function L.ReplyChance(helpers, target)
  if helpers <= 0 then return 1 end
  return math.min(1, target / helpers)
end

-- Offers: { name, inGroup, recent }. Favour helpers not in a group and with
-- fewer recent invites; skip names in `tried`. (Grouped helpers are ones
-- leading a HopAway-only party; 0.1.0 helpers offer from any small party.)
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
-- Settings and realm type
---------------------------------------------------------------------------

L.OPTION_KEYS = { "share", "help", "autoInvite", "autoAccept" }

-- Everything on: what makes sharing and hopping work best. Used on PvE
-- realms by default, and by "/hop on".
L.RECOMMENDED = { share = true, help = true, autoInvite = true, autoAccept = true }

-- What one outdoor zone says about the realm: "pvp" or nil (no clue).
-- GetZonePVPInfo() returns "contested" only on PvP realms. A missing PvP
-- type proves nothing: WoW: Forever's PvP realm reports none either (0.3.0
-- and older took it for PvE and turned everything on there).
function L.ZoneRealmEvidence(pvpType, inInstance)
  if inInstance then return nil end
  if pvpType == "contested" then return "pvp" end
  return nil
end

-- Realms whose name says the ruleset, like "ClassicBetaPvP" on WoW: Forever.
function L.RealmNameHint(realm)
  realm = (realm or ""):lower()
  if realm:find("pvp", 1, true) then return "pvp" end
  if realm:find("pve", 1, true) then return "pve" end
  return nil
end

-- Settings a character starts with: all on for PvE, all off for PvP or when
-- the realm type isn't known yet.
function L.StartSettings(realmType)
  local out = {}
  for _, k in ipairs(L.OPTION_KEYS) do out[k] = realmType == "pve" and L.RECOMMENDED[k] or false end
  return out
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
