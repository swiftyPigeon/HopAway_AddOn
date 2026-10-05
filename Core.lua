-- Core.lua: settings, safe event dispatch, throttled addon messages, /hop.
local ADDON, ns = ...
local L = ns.Logic

ns.PREFIX = "HopAway"     -- addon message prefix (max 16 chars)
ns.CHANNEL = "HopAwayNet" -- hidden custom channel for announces and asks

local DEFAULTS = {
  share = false,      -- announce my layer
  help = false,       -- answer asks from players who want to join my layer
  autoInvite = false, -- invite askers without a popup
  autoAccept = false, -- accept the invite from the helper I asked
  minimap = { angle = 250, hide = false },
}

local function CopyDefaults(src, dst)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      CopyDefaults(v, dst[k])
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

function ns.Print(msg, ...)
  if select("#", ...) > 0 then msg = msg:format(...) end
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffHopAway|r: " .. msg)
end

---------------------------------------------------------------------------
-- Errors never escape: every handler and timer runs through ns.Safe.
---------------------------------------------------------------------------

local lastError = 0
function ns.Safe(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and GetTime() - lastError > 10 then
    lastError = GetTime()
    ns.Print("|cffff6060error:|r %s", tostring(err))
  end
end

function ns.After(seconds, fn)
  C_Timer.After(seconds, function() ns.Safe(fn) end)
end

function ns.Every(seconds, fn)
  return C_Timer.NewTicker(seconds, function() ns.Safe(fn) end)
end

---------------------------------------------------------------------------
-- Events and addon messages
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local eventHandlers, msgHandlers = {}, {}

function ns.On(event, fn)
  if not eventHandlers[event] then
    eventHandlers[event] = {}
    eventFrame:RegisterEvent(event)
  end
  table.insert(eventHandlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(eventHandlers[event]) do ns.Safe(fn, ...) end
end)

function ns.OnMessage(kind, fn)
  msgHandlers[kind] = fn
end

-- Announces and asks go to the channel; everything else is a whisper.
local CHANNEL_KINDS = { A = true, Q = true }

ns.On("CHAT_MSG_ADDON", function(prefix, text, chatType, sender)
  if prefix ~= ns.PREFIX or not ns.me then return end
  sender = L.FullName(sender, ns.realm)
  if not sender or sender == ns.me then return end
  local msg = L.Decode(text)
  if not msg then return end
  if chatType ~= (CHANNEL_KINDS[msg.kind] and "CHANNEL" or "WHISPER") then return end
  local fn = msgHandlers[msg.kind]
  if fn then fn(msg, sender) end
end)

function ns.ChannelId()
  local id = GetChannelName(ns.CHANNEL)
  if id and id > 0 then return id end
end

-- Outgoing messages wait in a queue drained by a token bucket, well under
-- the game's addon message limits. A `key` replaces a queued message with
-- the same key (so we never stack up several announces).
local queue = {}
local bucket = L.NewBucket(5, 1, 0)

function ns.Send(kind, fields, chatType, target, key)
  local text = L.Encode(kind, fields)
  if not text then return end
  if key then
    for _, m in ipairs(queue) do
      if m.key == key then m.text = text; return end
    end
  end
  if #queue >= 20 then return end
  queue[#queue + 1] = { text = text, chatType = chatType, target = target, key = key }
end

local function Flush()
  local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
  local now = GetTime()
  while queue[1] and L.BucketTake(bucket, now) do
    local m = table.remove(queue, 1)
    local target = m.target
    if m.chatType == "CHANNEL" then target = ns.ChannelId() end
    if target then send(ns.PREFIX, m.text, m.chatType, target) end
  end
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

ns.OPTION_NAMES = {
  share = "Share my layer",
  help = "Layer help",
  autoInvite = "Auto-invite askers",
  autoAccept = "Auto-accept my helper's invite",
}

function ns.SetOption(key, value)
  value = value and true or false
  ns.db[key] = value
  ns.Print("%s: %s", ns.OPTION_NAMES[key], value and "|cff60ff60on|r" or "|cffff6060off|r")
  -- Helpers must be announced to be found, so help implies share.
  if key == "help" and value and not ns.db.share then
    ns.db.share = true
    ns.Print("Layer help needs your layer shared, so sharing is now on too.")
  elseif key == "share" and not value and ns.db.help then
    ns.db.help = false
    ns.Print("Layer help needs your layer shared, so layer help is now off too.")
  end
  ns.Layers.RequestAnnounce()
  ns.UI.Refresh()
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local SLASH_OPTIONS = { share = "share", help = "help", autoinvite = "autoInvite", autoaccept = "autoAccept" }

local function Usage()
  ns.Print("commands:")
  ns.Print("  /hop away - ask for an invite to another layer of this zone")
  ns.Print("  /hop cancel - stop the current hop")
  ns.Print("  /hop status - your layer, known layers, hop state")
  ns.Print("  /hop share|help|autoinvite|autoaccept on|off")
  ns.Print("  /hop show - toggle the layer window;  /hop minimap - toggle the minimap button")
end

local function HandleSlash(input)
  local cmd, arg = input:lower():match("^%s*(%S*)%s*(%S*)")
  if cmd == "away" then
    ns.Hop.Away()
  elseif cmd == "cancel" then
    ns.Hop.Cancel()
  elseif cmd == "status" then
    for _, line in ipairs(ns.Hop.StatusLines()) do ns.Print(line) end
  elseif cmd == "show" then
    ns.UI.Toggle()
  elseif cmd == "minimap" then
    ns.db.minimap.hide = not ns.db.minimap.hide
    ns.UI.UpdateMinimap()
  elseif SLASH_OPTIONS[cmd] and (arg == "on" or arg == "off") then
    ns.SetOption(SLASH_OPTIONS[cmd], arg == "on")
  else
    Usage()
  end
end

SLASH_HOPAWAY1 = "/hop"
SLASH_HOPAWAY2 = "/hopaway"
SlashCmdList.HOPAWAY = function(input) ns.Safe(HandleSlash, input or "") end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------

ns.On("ADDON_LOADED", function(name)
  if name ~= ADDON then return end
  HopAwayDB = CopyDefaults(DEFAULTS, HopAwayDB or {})
  ns.db = HopAwayDB
end)

ns.On("PLAYER_LOGIN", function()
  ns.realm = GetNormalizedRealmName() or (GetRealmName() or ""):gsub("[%s%-]", "")
  ns.me = L.FullName(UnitName("player"), ns.realm)
  C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
  ns.Every(0.2, Flush)
  ns.Layers.Init()
  ns.UI.Init()
end)
