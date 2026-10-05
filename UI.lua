-- UI.lua: minimap button, layer window and popups.
local _, ns = ...
local UI = {}
ns.UI = UI

local MAX_ROWS = 8
local ROW_H = 18
local TOP_H = 52     -- title + zone line
local BOTTOM_H = 186 -- note, hop button, status, checkboxes
local WIDTH = 260

local frame, rows, checks, minimapButton

---------------------------------------------------------------------------
-- Popups
---------------------------------------------------------------------------

StaticPopupDialogs.HOPAWAY_HELP = {
  text = "%s wants to join your layer (HopAway).\nInvite them? They'll leave the group on their own after moving.",
  button1 = ACCEPT,
  button2 = DECLINE,
  OnAccept = function(_, data) ns.Safe(ns.Hop.HelpAnswer, data, "accept") end,
  OnCancel = function(_, data, reason)
    ns.Safe(ns.Hop.HelpAnswer, data, reason == "timeout" and "timeout" or "decline")
  end,
  OnHide = function(self) ns.Safe(ns.Hop.HelpPopupHidden, self.data) end,
  timeout = 20,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

StaticPopupDialogs.HOPAWAY_LEAVE = {
  text = "HopAway hasn't seen your layer change yet. Maybe there are no NPCs nearby, " ..
    "or the game's layer cooldown blocked the move.\n\nLeave the group now?",
  button1 = "Leave group",
  button2 = "Stay",
  OnAccept = function() ns.Safe(ns.Hop.LeaveNow) end,
  OnCancel = function() ns.Safe(ns.Hop.StayGrouped) end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Layer window
---------------------------------------------------------------------------

local CHECKS = { "share", "help", "autoInvite", "autoAccept" }

local function Render()
  local layers = ns.Layers.KnownLayers()
  local mine = ns.Layers.GetLayer()
  frame.zone:SetText(("%s - your layer: %s"):format(
    ns.Layers.GetMapName() or "Not in a zone",
    mine and ("#" .. mine) or "unknown"))

  local n = math.min(#layers, MAX_ROWS)
  for i, row in ipairs(rows) do
    local layer = layers[i]
    if i <= n then
      row.uid = layer.uid
      row.clickable = not layer.mine and layer.helpers > 0
      local text = ("#%s   %d user(s), %d helper(s)"):format(layer.uid, layer.users, layer.helpers)
      if layer.mine then
        text = "|cff60ff60" .. text .. "  (you)|r"
      elseif layer.helpers == 0 then
        text = "|cff808080" .. text .. "|r"
      end
      row.text:SetText(text)
      row:Show()
    else
      row:Hide()
    end
  end
  frame.empty:SetShown(n == 0)
  frame:SetHeight(TOP_H + math.max(n, 1) * ROW_H + BOTTOM_H)

  frame.hopButton:SetText(ns.Hop.IsIdle() and "Hop to another layer" or "Cancel hop")
  frame.status:SetText("Hop: " .. ns.Hop.Describe())
  for _, cb in ipairs(checks) do cb:SetChecked(ns.db[cb.key]) end
end

local function CreateWindow()
  frame = CreateFrame("Frame", "HopAwayFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  frame:SetSize(WIDTH, TOP_H + ROW_H + BOTTOM_H)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:Hide()
  table.insert(UISpecialFrames, "HopAwayFrame") -- Escape closes it

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", 0, -12)
  title:SetText("HopAway")

  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)

  frame.zone = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.zone:SetPoint("TOPLEFT", 14, -32)
  frame.zone:SetWidth(WIDTH - 28)
  frame.zone:SetJustifyH("LEFT")

  frame.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.empty:SetPoint("TOPLEFT", 14, -TOP_H - 2)
  frame.empty:SetText("No HopAway users known in this zone yet.")

  rows = {}
  for i = 1, MAX_ROWS do
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(WIDTH - 24, ROW_H)
    row:SetPoint("TOPLEFT", 12, -TOP_H - (i - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 4, 0)
    row:SetScript("OnClick", function(self)
      if self.clickable then ns.Safe(ns.Hop.Away, self.uid) end
    end)
    rows[i] = row
  end

  -- Bottom part, anchored to the frame's bottom edge.
  local note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("BOTTOMLEFT", 14, 152)
  note:SetWidth(WIDTH - 28)
  note:SetJustifyH("LEFT")
  note:SetText("Counts are HopAway users only, not real crowd sizes. " ..
    "Click a layer with helpers to hop there. Any choice is a guess.")

  frame.hopButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.hopButton:SetSize(200, 22)
  frame.hopButton:SetPoint("BOTTOM", 0, 124)
  frame.hopButton:SetScript("OnClick", function()
    if ns.Hop.IsIdle() then ns.Safe(ns.Hop.Away) else ns.Safe(ns.Hop.Cancel) end
  end)

  frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  frame.status:SetPoint("BOTTOMLEFT", 14, 104)
  frame.status:SetWidth(WIDTH - 28)
  frame.status:SetJustifyH("LEFT")

  checks = {}
  for i, key in ipairs(CHECKS) do
    local cb = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("BOTTOMLEFT", 10, 10 + (#CHECKS - i) * 22)
    cb.key = key
    local label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    label:SetText(ns.OPTION_NAMES[key])
    cb:SetScript("OnClick", function(self) ns.Safe(ns.SetOption, self.key, self:GetChecked()) end)
    checks[i] = cb
  end

  frame:SetScript("OnShow", function() ns.Safe(Render) end)
end

function UI.Refresh()
  if frame and frame:IsShown() then Render() end
end

function UI.Toggle()
  if not frame then return end
  frame:SetShown(not frame:IsShown())
end

---------------------------------------------------------------------------
-- Minimap button: the round framed button on the minimap edge (same look
-- as LibDBIcon buttons, without the library). Drag it around the edge.
---------------------------------------------------------------------------

local function PlaceMinimapButton()
  local angle = math.rad(ns.db.minimap.angle)
  local radius = Minimap:GetWidth() / 2 + 5
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function DragUpdate()
  local mx, my = Minimap:GetCenter()
  local scale = Minimap:GetEffectiveScale()
  local cx, cy = GetCursorPosition()
  ns.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
  PlaceMinimapButton()
end

local function CreateMinimapButton()
  local b = CreateFrame("Button", "HopAwayMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 7, -5)

  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture("Interface\\Icons\\Spell_Arcane_Blink")
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  icon:SetPoint("TOPLEFT", 7, -6)

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT")

  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then ns.Safe(ns.Hop.Away) else UI.Toggle() end
  end)
  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function() ns.Safe(DragUpdate) end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("HopAway")
    for _, line in ipairs(ns.Hop.StatusLines()) do
      GameTooltip:AddLine(line, 1, 1, 1, true)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: show layers", 0.6, 0.8, 1)
    GameTooltip:AddLine("Right-click: hop to another layer", 0.6, 0.8, 1)
    GameTooltip:AddLine("Drag: move this button", 0.6, 0.8, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  minimapButton = b
  PlaceMinimapButton()
end

function UI.UpdateMinimap()
  if not minimapButton then return end
  minimapButton:SetShown(not ns.db.minimap.hide)
end

function UI.Init()
  CreateWindow()
  CreateMinimapButton()
  UI.UpdateMinimap()
  ns.Every(1, UI.Refresh) -- keeps the status countdown current while open
end
