-- Hop.lua: the asker side (ask -> offers -> request -> invite -> leave) and
-- the helper side (answer asks, invite askers).
local _, ns = ...
local L = ns.Logic
local Hop = {}
ns.Hop = Hop

local COLLECT_TIME = 3     -- seconds to collect offers after an ask
local REQUEST_TIMEOUT = 25 -- wait for a helper to react (their popup lasts 20 s)
local INVITE_GRACE = 40    -- helper says "invite sent": wait for the group join
local MOVE_TIMEOUT = 20    -- in the group but no layer change seen: ask the player
local MAX_HELPERS = 3      -- helpers to try per ask
local OFFER_TARGET = 6     -- offers we'd like per ask
local OFFER_TTL = 60       -- a helper's offer is valid this long
local RECENT_WINDOW = 600  -- "recent invites" window for helpers

---------------------------------------------------------------------------
-- Asker state machine. Each state change bumps `gen`, so timers started in
-- an earlier state do nothing.
---------------------------------------------------------------------------

-- states: idle, collecting, requesting, grouped
local hop = { state = "idle", gen = 0, failures = 0, nextAllowed = 0 }

local function SetState(state)
  hop.state = state
  hop.gen = hop.gen + 1
  ns.UI.Refresh()
end

local function Later(seconds, fn)
  local gen = hop.gen
  ns.After(seconds, function() if hop.gen == gen then fn() end end)
end

local function Short(name)
  return Ambiguate(name, "short")
end

local function LeaveGroup()
  local leave = (C_PartyInfo and C_PartyInfo.LeaveParty) or LeaveParty
  leave()
end

local function Reset()
  hop.nonce, hop.offers, hop.tried, hop.helper, hop.target, hop.origin = nil, nil, nil, nil, nil, nil
  SetState("idle")
end

local function Fail(reason)
  hop.failures = hop.failures + 1
  local wait = L.Backoff(hop.failures)
  hop.nextAllowed = GetTime() + wait
  ns.Print("%s You can ask again in %d s.", reason, wait)
  Reset()
end

-- Why we can't hop right now, or nil.
local function Blocker()
  if IsInInstance() then return "You can't hop inside an instance." end
  if InCombatLockdown() or UnitAffectingCombat("player") then return "You can't hop in combat." end
  if IsInGroup() then return "You're already in a group. Leave it first." end
  if not ns.Layers.GetMap() then return "HopAway only works in an outdoor zone." end
  if not ns.Layers.GetLayer() then
    return "Your layer isn't known yet. Target or mouse over a couple of NPCs."
  end
  if not ns.Layers.ChannelReady() then
    return "Not connected to the HopAway channel yet. Try again in a few seconds."
  end
end

function Hop.Away(targetUid)
  if hop.state ~= "idle" then
    ns.Print("Already hopping. Type /hop cancel to stop.")
    return
  end
  local wait = hop.nextAllowed - GetTime()
  if wait > 0 then
    ns.Print("Nobody invited you last time. You can ask again in %d s.", math.ceil(wait))
    return
  end
  local why = Blocker()
  if why then ns.Print(why); return end

  local mine = ns.Layers.GetLayer()
  if targetUid == mine then ns.Print("You're already on that layer."); return end
  if targetUid and ns.Layers.HelpersOn(targetUid) == 0 then
    ns.Print("Nobody on layer #%s has layer help turned on.", targetUid)
    return
  end
  targetUid = targetUid or L.PickLayer(ns.Layers.KnownLayers(), mine, math.random)
  if not targetUid then
    ns.Print("No other layer with a helper is known in this zone. HopAway only knows " ..
      "about other HopAway users who turned on layer help.")
    return
  end

  hop.target, hop.origin = targetUid, mine
  hop.nonce = L.Nonce(math.random)
  hop.offers, hop.tried = {}, {}
  SetState("collecting")
  ns.Send("Q", { map = ns.Layers.GetMap(), uid = targetUid, nonce = hop.nonce }, "CHANNEL")
  ns.Print("Asking for an invite to layer #%s. This is a guess: HopAway can't see how " ..
    "crowded layers really are.", targetUid)
  Later(COLLECT_TIME, Hop.NextHelper)
end

-- Ask the next helper (random, favouring helpers not in a group and with
-- fewer recent invites) or give up after MAX_HELPERS.
function Hop.NextHelper()
  local tried = 0
  for _ in pairs(hop.tried) do tried = tried + 1 end
  if tried >= MAX_HELPERS then return Fail("None of the helpers invited you.") end
  local offer = L.PickOffer(hop.offers, hop.tried, math.random)
  if not offer then
    return Fail(tried == 0 and "No helper answered." or "No other helper answered.")
  end
  hop.tried[offer.name] = true
  hop.helper = offer.name
  SetState("requesting")
  ns.Send("R", { nonce = hop.nonce }, "WHISPER", offer.name)
  ns.Print("Asked %s for an invite...", Short(offer.name))
  Later(REQUEST_TIMEOUT, function()
    ns.Print("%s didn't invite you.", Short(offer.name))
    Hop.NextHelper()
  end)
end

function Hop.Cancel()
  if hop.state == "idle" then ns.Print("No hop in progress."); return end
  StaticPopup_Hide("HOPAWAY_LEAVE")
  Reset()
  ns.Print("Hop cancelled.")
end

ns.OnMessage("O", function(msg, sender)
  if (hop.state ~= "collecting" and hop.state ~= "requesting") or msg.nonce ~= hop.nonce then return end
  if #hop.offers >= 20 then return end
  for _, o in ipairs(hop.offers) do
    if o.name == sender then return end
  end
  table.insert(hop.offers, { name = sender, inGroup = msg.inGroup, recent = msg.recent })
end)

ns.OnMessage("D", function(msg, sender)
  if hop.state ~= "requesting" or msg.nonce ~= hop.nonce or sender ~= hop.helper then return end
  ns.Print("%s can't invite you right now.", Short(sender))
  Hop.NextHelper()
end)

ns.OnMessage("I", function(msg, sender)
  if hop.state ~= "requesting" or msg.nonce ~= hop.nonce or sender ~= hop.helper then return end
  ns.Print("%s is inviting you.", Short(sender))
  SetState("requesting") -- restart the timeout with more time to click the invite
  Later(INVITE_GRACE, function()
    ns.Print("The invite from %s wasn't accepted.", Short(sender))
    Hop.NextHelper()
  end)
end)

-- Never auto-accept strangers: only the exact helper we asked, and only if
-- the player turned that on. Otherwise just say who the invite is from.
ns.On("PARTY_INVITE_REQUEST", function(name)
  if hop.state ~= "requesting" or not hop.helper then return end
  if L.FullName(name, ns.realm) ~= hop.helper then
    ns.Print("This invite is from %s, not from your HopAway helper %s.", name, Short(hop.helper))
    return
  end
  if ns.db.autoAccept then
    AcceptGroup()
    StaticPopup_Hide("PARTY_INVITE")
    ns.Print("Accepted the invite from your helper %s.", Short(hop.helper))
  else
    ns.Print("This invite is from %s, your HopAway helper. Accept it to change layer.", Short(hop.helper))
  end
end)

ns.On("GROUP_ROSTER_UPDATE", function()
  if hop.state == "requesting" and IsInGroup() then
    SetState("grouped")
    ns.Print("Joined the group. Waiting for the layer change (looking at an NPC helps)...")
    Later(MOVE_TIMEOUT, function() StaticPopup_Show("HOPAWAY_LEAVE") end)
  elseif hop.state == "grouped" and not IsInGroup() then
    StaticPopup_Hide("HOPAWAY_LEAVE")
    ns.Print("You left the group before a layer change was seen.")
    Reset()
  end
end)

-- Called by Layers when a new zoneUID is confirmed.
function Hop.OnLayerChanged(new, old)
  if hop.state ~= "grouped" or new == hop.origin then return end
  StaticPopup_Hide("HOPAWAY_LEAVE")
  ns.Print("Layer changed: #%s -> #%s. Leaving the group.", tostring(old or hop.origin), new)
  hop.failures, hop.nextAllowed = 0, 0
  Reset() -- first, so the roster update doesn't report an early leave
  LeaveGroup()
end

-- "Leave the group?" popup answers.
function Hop.LeaveNow()
  Reset()
  if IsInGroup() then LeaveGroup() end
end

function Hop.StayGrouped()
  if hop.state ~= "grouped" then return end
  Reset()
  ns.Print("Staying in the group. HopAway won't leave it for you.")
end

---------------------------------------------------------------------------
-- Helper side
---------------------------------------------------------------------------

local offered = {}                      -- [asker] = { nonce, t }
local perAsker = L.NewKeyed(OFFER_TTL)  -- one offer per asker per minute
local invites = {}                      -- times we invited someone
local pending                           -- request shown in the popup

local function RecentInvites(now)
  for i = #invites, 1, -1 do
    if now - invites[i] > RECENT_WINDOW then table.remove(invites, i) end
  end
  return #invites
end

local function CanHelp()
  if not (ns.db.help and ns.db.share) then return false end
  if IsInInstance() or InCombatLockdown() then return false end
  if hop.state ~= "idle" then return false end
  if IsInRaid() then return false end
  if IsInGroup() and (not UnitIsGroupLeader("player") or GetNumGroupMembers() >= 5) then return false end
  return true
end

local function Invite(name, nonce)
  local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
  invite(Ambiguate(name, "none"))
  table.insert(invites, GetTime())
  ns.Send("I", { nonce = nonce }, "WHISPER", name)
  ns.Print("Invited %s to your layer. They'll leave the group once they've moved.", Short(name))
end

local function Decline(name, nonce, reason)
  ns.Send("D", { nonce = nonce, reason = reason }, "WHISPER", name)
end

ns.OnMessage("Q", function(msg, sender)
  if not CanHelp() then return end
  if msg.map ~= ns.Layers.GetMap() or msg.uid ~= ns.Layers.GetLayer() then return end
  -- Answer with a chance scaled to the number of helpers here (~6 offers).
  if math.random() > L.ReplyChance(ns.Layers.HelpersOn(msg.uid), OFFER_TARGET) then return end
  local now = GetTime()
  if not L.KeyedAllow(perAsker, sender, now) then return end
  offered[sender] = { nonce = msg.nonce, t = now }
  local inGroup, recent = IsInGroup(), RecentInvites(now)
  ns.After(math.random(), function() -- spread replies out a little
    ns.Send("O", { nonce = msg.nonce, inGroup = inGroup, recent = recent }, "WHISPER", sender)
  end)
end)

ns.OnMessage("R", function(msg, sender)
  local o = offered[sender]
  if not o or o.nonce ~= msg.nonce or GetTime() - o.t > OFFER_TTL then return end
  offered[sender] = nil
  if not CanHelp() or pending then return Decline(sender, msg.nonce, "busy") end
  if ns.db.autoInvite then return Invite(sender, msg.nonce) end
  pending = { name = sender, nonce = msg.nonce }
  StaticPopup_Show("HOPAWAY_HELP", Short(sender), nil, pending)
end)

-- Popup answers. reason is "accept", "decline" or "timeout".
function Hop.HelpAnswer(data, reason)
  if not data or data ~= pending then return end
  pending = nil
  if reason == "accept" and CanHelp() then
    Invite(data.name, data.nonce)
  else
    Decline(data.name, data.nonce, reason == "accept" and "busy" or reason)
  end
end

-- Popup closed some other way (e.g. replaced by another popup).
function Hop.HelpPopupHidden(data)
  if data and data == pending then Hop.HelpAnswer(data, "decline") end
end

---------------------------------------------------------------------------
-- Status text
---------------------------------------------------------------------------

function Hop.Describe()
  local s = hop.state
  if s == "collecting" then return ("asking for an invite to layer #%s..."):format(hop.target) end
  if s == "requesting" then return ("waiting for %s to invite you..."):format(Short(hop.helper)) end
  if s == "grouped" then return "in the group, waiting for the layer change..." end
  local wait = hop.nextAllowed - GetTime()
  if wait > 0 then return ("can ask again in %d s"):format(math.ceil(wait)) end
  return "ready"
end

function Hop.IsIdle()
  return hop.state == "idle"
end

local function OnOff(v) return v and "on" or "off" end

function Hop.StatusLines()
  local lines = {}
  local mine = ns.Layers.GetLayer()
  lines[#lines + 1] = ("Zone: %s, your layer: %s"):format(
    ns.Layers.GetMapName() or "none (instance or not a zone)",
    mine and ("#" .. mine) or "unknown (target a few NPCs)")
  local layers = ns.Layers.KnownLayers()
  if #layers == 0 then
    lines[#lines + 1] = "No HopAway users known in this zone."
  end
  for _, l in ipairs(layers) do
    lines[#lines + 1] = ("  #%s: %d user(s), %d helper(s)%s"):format(
      l.uid, l.users, l.helpers, l.mine and " (you)" or "")
  end
  lines[#lines + 1] = "Counts include HopAway users only, not real player numbers."
  lines[#lines + 1] = "Hop: " .. Hop.Describe()
  lines[#lines + 1] = ("Share %s, layer help %s, auto-invite %s, auto-accept %s"):format(
    OnOff(ns.db.share), OnOff(ns.db.help), OnOff(ns.db.autoInvite), OnOff(ns.db.autoAccept))
  return lines
end
