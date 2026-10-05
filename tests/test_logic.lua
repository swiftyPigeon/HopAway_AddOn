-- Tests for Logic.lua. Run from the addon folder or anywhere:
--   lua tests/test_logic.lua
local dir = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\]") or "."
local L = dofile(dir .. "/Logic.lua")

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- Deterministic "random" numbers.
local function seq(...)
  local values, i = { ... }, 0
  return function() i = i % #values + 1; return values[i] end
end

test("ParseGUID creature", function()
  local uid, key = L.ParseGUID("Creature-0-4395-0-1234-3100-00001A2B3C")
  eq(uid, "1234"); eq(key, "3100-00001A2B3C")
end)

test("ParseGUID vehicle", function()
  eq(L.ParseGUID("Vehicle-0-4395-0-77-1-ABC"), "77")
end)

test("ParseGUID rejects players, pets and junk", function()
  eq(L.ParseGUID("Player-4395-0ABCDEF"), nil)
  eq(L.ParseGUID("Pet-0-4395-0-1234-416-0100000001"), nil)
  eq(L.ParseGUID("GameObject-0-4395-0-1234-1731-00001A2B3C"), nil)
  eq(L.ParseGUID(nil), nil)
  eq(L.ParseGUID("Creature-0-1-2"), nil)
end)

test("Detector needs two different NPCs", function()
  local d = L.NewDetector({ need = 2, quiet = 3 })
  eq(d:Observe("100", "a", 0), nil)
  eq(d:Observe("100", "a", 1), nil, "same NPC twice")
  eq(d:Observe("100", "b", 2), "100")
  eq(d.current, "100")
end)

test("Detector waits until the old layer is quiet", function()
  local d = L.NewDetector({ need = 2, quiet = 3 })
  d:Observe("100", "a", 0); d:Observe("100", "b", 0)
  d:Observe("200", "c", 1)
  eq(d:Observe("200", "d", 2), nil, "old layer seen 2 s ago")
  local new, old = d:Evaluate(3.5)
  eq(new, "200"); eq(old, "100")
end)

test("Detector ignores a single border creature", function()
  local d = L.NewDetector({ need = 2, quiet = 3 })
  d:Observe("100", "a", 0); d:Observe("100", "b", 0)
  d:Observe("999", "x", 10)
  eq(d:Evaluate(20), nil)
  eq(d.current, "100")
end)

test("Detector doesn't flip back to stale readings", function()
  local d = L.NewDetector({ need = 2, quiet = 3 })
  d:Observe("100", "a", 0); d:Observe("100", "b", 0)
  d:Observe("200", "c", 5); d:Observe("200", "d", 5)
  eq(d.current, "200")
  eq(d:Observe("100", "a", 10), nil)
  eq(d:Evaluate(20), nil)
  eq(d.current, "200")
end)

test("Encode/Decode round trip", function()
  local text = L.Encode("A", { map = 1429, uid = "1234", help = true })
  eq(text, "A:1:1429:1234:1")
  local msg = L.Decode(text)
  eq(msg.kind, "A"); eq(msg.map, 1429); eq(msg.uid, "1234"); eq(msg.help, true)

  msg = L.Decode(L.Encode("O", { nonce = "ab12cd", inGroup = false, recent = 3 }))
  eq(msg.nonce, "ab12cd"); eq(msg.inGroup, false); eq(msg.recent, 3)
end)

test("Encode rejects bad fields", function()
  eq(L.Encode("Q", { map = 1, uid = "12", nonce = "a:b" }), nil)
  eq(L.Encode("Q", { map = 1, uid = "x", nonce = "abc" }), nil)
  eq(L.Encode("Q", { map = 1.5, uid = "1", nonce = "abc" }), nil)
  eq(L.Encode("Z", {}), nil)
end)

test("Decode rejects bad messages", function()
  eq(L.Decode("A:2:1429:1234:1"), nil, "version")
  eq(L.Decode("A:1:1429:1234"), nil, "too few fields")
  eq(L.Decode("A:1:1429:1234:1:extra"), nil, "too many fields")
  eq(L.Decode("A:1:abc:1234:1"), nil, "not a number")
  eq(L.Decode("A:1:1429:1234:yes"), nil, "not a boolean")
  eq(L.Decode("X:1"), nil, "unknown kind")
  eq(L.Decode(""), nil); eq(L.Decode(nil), nil)
  eq(L.Decode(string.rep("a", 300)), nil)
end)

test("Nonce is 6 alphanumerics", function()
  local n = L.Nonce(seq(0, 0.5, 0.99))
  eq(#n, 6); eq(n:match("^%w+$"), n)
end)

test("FullName", function()
  eq(L.FullName("Bob", "Nightslayer"), "Bob-Nightslayer")
  eq(L.FullName("Bob-Other", "Nightslayer"), "Bob-Other")
  eq(L.FullName("Bob", "Living Flame"), "Bob-LivingFlame")
  eq(L.FullName(nil, "x"), nil)
end)

test("LayersInMap counts users and helpers, adds me, expires", function()
  local peers = {}
  L.UpdatePeer(peers, "A", 10, "100", true, 0)
  L.UpdatePeer(peers, "B", 10, "100", false, 0)
  L.UpdatePeer(peers, "C", 10, "200", true, 0)
  L.UpdatePeer(peers, "D", 11, "300", true, 0)   -- other zone
  L.UpdatePeer(peers, "E", 10, "400", true, -999) -- too old
  local layers = L.LayersInMap(peers, 10, 100, 500, { uid = "200", help = false })
  eq(#layers, 2)
  eq(layers[1].uid, "100"); eq(layers[1].users, 2); eq(layers[1].helpers, 1); eq(layers[1].mine, false)
  eq(layers[2].uid, "200"); eq(layers[2].users, 2); eq(layers[2].helpers, 1); eq(layers[2].mine, true)
  L.ExpirePeers(peers, 100, 500)
  eq(peers.E, nil); eq(peers.A ~= nil, true)
end)

test("PickLayer skips my layer and layers without helpers", function()
  local layers = {
    { uid = "100", helpers = 5 }, { uid = "200", helpers = 0 }, { uid = "300", helpers = 1 },
  }
  for _, r in ipairs({ 0, 0.3, 0.6, 0.99 }) do
    eq(L.PickLayer(layers, "100", function() return r end), "300")
  end
  eq(L.PickLayer({ { uid = "100", helpers = 3 } }, "100", math.random), nil)
end)

test("ReplyChance aims for ~6 offers", function()
  eq(L.ReplyChance(3, 6), 1)
  eq(L.ReplyChance(60, 6), 0.1)
  eq(L.ReplyChance(0, 6), 1)
end)

test("PickOffer skips tried and favours ungrouped, less busy helpers", function()
  local offers = {
    { name = "grouped", inGroup = true, recent = 0 },   -- weight 1
    { name = "free", inGroup = false, recent = 0 },     -- weight 3
    { name = "busy", inGroup = false, recent = 2 },     -- weight 1
  }
  eq(L.PickOffer(offers, {}, function() return 0.5 end).name, "free")
  eq(L.PickOffer(offers, { free = true }, function() return 0.1 end).name, "grouped")
  eq(L.PickOffer(offers, { grouped = true, free = true, busy = true }, math.random), nil)
  local counts = {}
  for _ = 1, 2000 do
    local o = L.PickOffer(offers, {}, math.random)
    counts[o.name] = (counts[o.name] or 0) + 1
  end
  assert(counts.free > counts.grouped * 2 and counts.free > counts.busy * 2, "weights")
end)

test("Backoff steps", function()
  eq(L.Backoff(0), 0); eq(L.Backoff(1), 20); eq(L.Backoff(2), 60); eq(L.Backoff(3), 180); eq(L.Backoff(9), 180)
end)

test("Bucket throttles bursts and refills", function()
  local b = L.NewBucket(2, 1, 0)
  eq(L.BucketTake(b, 0), true); eq(L.BucketTake(b, 0), true); eq(L.BucketTake(b, 0), false)
  eq(L.BucketTake(b, 0.5), false); eq(L.BucketTake(b, 1.1), true)
end)

test("Keyed throttle: once per key per interval", function()
  local k = L.NewKeyed(60)
  eq(L.KeyedAllow(k, "a", 0), true); eq(L.KeyedAllow(k, "a", 30), false)
  eq(L.KeyedAllow(k, "b", 30), true); eq(L.KeyedAllow(k, "a", 61), true)
end)

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
