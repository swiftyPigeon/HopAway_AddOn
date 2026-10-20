-- Hop.lua: the asker side (ask -> offers -> request -> invite -> leave) and
-- the helper side (answer asks, invite askers).
local _, ns = ...
local L = ns.Logic
local Hop = {}
ns.Hop = Hop

local COLLECT_TIME = 3     -- seconds to collect offers after an ask
local REQUEST_TIMEOUT = 25 -- wait for a helper to react (their popup lasts 20 s)
local INVITE_GRACE = 20    -- helper says "invite sent": accept within this, or we decline it
local MOVE_TIMEOUT = 20    -- in the group but no layer change seen: ask the player
local MAX_HELPERS = 3      -- helpers to try per ask
local OFFER_TARGET = 6     -- offers we'd like per ask
local OFFER_TTL = 60       -- a helper's offer is valid this long
local RECENT_WINDOW = 600  -- "recent invites" window for helpers
local CONTACT_TIMEOUT = 120 -- wait this long for a friend's or guildmate's invite
local CONTACTS_MAX = 4     -- friends/guildmates listed as a fallback
local CONTACT_TEXT = "Could you invite me to your group for a moment? " ..
  "I'm hopping layers with HopAway and will leave right away."

---------------------------------------------------------------------------
-- Asker state machine. Each state change bumps `gen`, so timers started in
-- an earlier state do nothing.
---------------------------------------------------------------------------

-- states: idle, collecting, requesting, grouped. hop.contact is set while
-- we wait for a friend or guildmate we whispered (no ask/offer round).
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
  hop.invited, hop.contact = nil, nil
  SetState("idle")
end

-- Turn down our helper's invite if it's still open, so it can't be accepted
-- late and the next helper's invite isn't blocked by it.
local function DeclinePending()
  if hop.invited and not IsInGroup() then
    DeclineGroup()
    StaticPopup_Hide("PARTY_INVITE")
  end
  hop.invited = nil
end

local function Fail(reason)
  hop.failures = hop.failures + 1
  local wait = L.Backoff(hop.failures)
  hop.nextAllowed = GetTime() + wait
  ns.Print("%s You can ask again in %d s.", reason, wait)
  Reset()
end

-- Why we can't hop right now, or nil.
local function Blocker(needChannel)
  if IsInInstance() then return "You can't hop inside an instance." end
  if InCombatLockdown() or UnitAffectingCombat("player") then return "You can't hop in combat." end
  if IsInGroup() then return "You're already in a group. Leave it first." end
  if not ns.Layers.GetMap() then return "HopAway only works in an outdoor zone." end
  if not ns.Layers.GetLayer() then
    return "Your layer isn't known yet. Target or mouse over a couple of NPCs."
  end
  if needChannel and not ns.Layers.ChannelReady() then
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
  local why = Blocker(true)
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
      "about other HopAway users who turned on layer help. You can ask a friend or " ..
      "guildmate in this zone from the window (/hop show).")
    return
  end

  hop.target, hop.origin = targetUid, mine
  hop.nonce = L.Nonce(math.random)
  hop.offers, hop.tried = {}, {}
  SetState("collecting")
  ns.Send("Q", { map = ns.Layers.GetMap(), uid = targetUid, nonce = hop.nonce }, "CHANNEL")
  ns.Print("Asking for an invite to layer #%s. HopAway favours layers where its users see " ..
    "fewer players, but that's a sample, not a headcount.", targetUid)
  Later(COLLECT_TIME, Hop.NextHelper)
end

-- Ask the next helper (random, favouring helpers not in a group and with
-- fewer recent invites) or give up after MAX_HELPERS.
function Hop.NextHelper()
  DeclinePending()
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

-- Fallback: ask a friend or guildmate in this zone by whisper. The game
-- only sends chat on a key press, so we open the whisper and the player
-- presses Enter. Their invite then runs the normal flow (auto-accept only
-- from them, leave after the layer change, or ask if nothing changes
-- because they were on our layer after all).
function Hop.AskContact(name)
  if hop.state ~= "idle" then
    ns.Print("Already hopping. Type /hop cancel to stop.")
    return
  end
  local why = Blocker(false)
  if why then ns.Print(why); return end
  hop.origin, hop.helper, hop.contact = ns.Layers.GetLayer(), name, true
  SetState("requesting")
  ChatFrame_OpenChat("/w " .. Ambiguate(name, "none") .. " " .. CONTACT_TEXT)
  ns.Print("Press Enter to whisper %s. If they're on another layer, joining their group " ..
    "moves you, and HopAway then leaves it.", Short(name))
  Later(CONTACT_TIMEOUT, function()
    ns.Print("No invite from %s.", Short(name))
    DeclinePending()
    Reset()
  end)
end

-- Online friends and guildmates in this zone, skipping HopAway users known
-- to be on our layer. Cached for a few seconds: the window refreshes often.
local contacts, contactsAt, rosterAsked = {}, -math.huge, -math.huge

function Hop.Contacts()
  local now = GetTime()
  if now - contactsAt < 5 then return contacts end
  contactsAt = now
  local zone = ns.Layers.GetMapName()
  if not zone then contacts = {}; return contacts end
  local list = {}
  if C_FriendList and C_FriendList.GetNumFriends then
    for i = 1, C_FriendList.GetNumFriends() do
      local f = C_FriendList.GetFriendInfoByIndex(i)
      if f then
        list[#list + 1] = { name = L.FullName(f.name, ns.realm), zone = f.area, online = f.connected, kind = "friend" }
      end
    end
  end
  if IsInGuild() then
    if now - rosterAsked > 30 then -- ask the server for fresh zones now and then
      rosterAsked = now
      local ask = (C_GuildInfo and C_GuildInfo.GuildRoster) or GuildRoster
      if ask then ask() end
    end
    for i = 1, GetNumGuildMembers() do
      local name, _, _, _, _, gzone, _, _, online = GetGuildRosterInfo(i)
      list[#list + 1] = { name = L.FullName(name, ns.realm), zone = gzone, online = online, kind = "guild" }
    end
  end
  contacts = L.ZoneContacts(list, zone, ns.me, ns.Layers.PeersOnMyLayer(), CONTACTS_MAX)
  return contacts
end

function Hop.Cancel()
  if hop.state == "idle" then ns.Print("No hop in progress."); return end
  StaticPopup_Hide("HOPAWAY_LEAVE")
  DeclinePending()
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
    ns.Print("The invite from %s wasn't accepted within %d s.", Short(sender), INVITE_GRACE)
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
  hop.invited = true
  if ns.db.autoAccept then
    AcceptGroup()
    StaticPopup_Hide("PARTY_INVITE")
    ns.Print("Accepted the invite from your helper %s.", Short(hop.helper))
  else
    ns.Print("This invite is from %s, your HopAway helper. Accept it within %d s to change layer.",
      Short(hop.helper), INVITE_GRACE)
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
  ns.Layers.MarkLeft(hop.origin)
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

-- Players we invited, by short name -> { invited = t, joined = t }. They
-- count as HopAway guests for GUEST_TIME after joining; one who stays longer
-- is a real groupmate. An invite nobody accepted is forgotten after INVITE_TIME.
local GUEST_TIME = 60
local INVITE_TIME = 30 -- the guest declines after 20 s, plus some slack
local guests = {}

-- True when we lead a party whose other members are all recent HopAway
-- guests, so more askers can join it. A group players made, a raid, or a
-- name we can't match all count as a real group: no guests land there.
function Hop.HopAwayGroup()
  if not IsInGroup() or IsInRaid() or not UnitIsGroupLeader("player") then return false end
  local n = GetNumGroupMembers()
  if n >= 5 then return false end
  local now = GetTime()
  for i = 1, n - 1 do
    local g = guests[UnitName("party" .. i) or ""]
    if not g or (not g.joined and now - g.invited > INVITE_TIME) then return false end
    g.joined = g.joined or now -- Layers calls this every second, close enough
    if now - g.joined > GUEST_TIME then return false end
  end
  return true
end

local function CanHelp()
  if not (ns.db.help and ns.db.share) then return false end
  if IsInInstance() then return false end
  -- In a crowded zone helpers are fighting most of the time. With
  -- auto-invite the invite needs no click, so combat doesn't stop it.
  if not ns.db.autoInvite and (InCombatLockdown() or UnitAffectingCombat("player")) then return false end
  if hop.state ~= "idle" then return false end
  if IsInGroup() and not Hop.HopAwayGroup() then return false end
  return true
end

local function Invite(name, nonce)
  local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
  invite(Ambiguate(name, "none"))
  local now = GetTime()
  for k, g in pairs(guests) do
    if now - (g.joined or g.invited) > (g.joined and GUEST_TIME or INVITE_TIME) then guests[k] = nil end
  end
  guests[Short(name)] = { invited = now }
  table.insert(invites, now)
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

-- One layer as text, shared by /hop status and the window.
function Hop.LayerText(l)
  local text = ("#%s  %d user%s, %d helper%s"):format(
    l.uid, l.users, l.users == 1 and "" or "s", l.helpers, l.helpers == 1 and "" or "s")
  if l.crowd then text = text .. (", ~%d seen"):format(l.crowd) end
  if l.mine then
    text = text .. "  (you)"
  elseif l.leftAgo then
    text = text .. ("  left %d min ago"):format(math.max(1, math.floor(l.leftAgo / 60)))
  end
  return text
end

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
    lines[#lines + 1] = "  " .. Hop.LayerText(l)
  end
  lines[#lines + 1] = "Users/helpers are HopAway users only. \"Seen\" is how many players " ..
    "HopAway users noticed nearby: a sample, not a headcount."
  lines[#lines + 1] = "Hop: " .. Hop.Describe()
  local realm = ns.Setup.RealmType()
  lines[#lines + 1] = "Realm: " .. (realm == "pvp" and "PvP" or realm == "pve" and "PvE" or
    "type not known yet")
  lines[#lines + 1] = ("Share %s, layer help %s, auto-invite %s, auto-accept %s"):format(
    OnOff(ns.db.share), OnOff(ns.db.help), OnOff(ns.db.autoInvite), OnOff(ns.db.autoAccept))
  return lines
end
