-- SoulSource minimap button: left-click for options, right-click for the
-- shard list, drag to move it around the minimap.

local ADDON_NAME, ns = ...

local db
local button

local function UpdatePosition()
    local angle = math.rad(db.minimap.angle or 200)
    local radius = (Minimap:GetWidth() / 2) + 10
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    UpdatePosition()
end

local function CreateButton()
    local b = CreateFrame("Button", "SoulSourceMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")

    local background = b:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexture(ns.SHARD_ICON)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    b:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then ns.ToggleWindow() else ns.ToggleOptions() end
    end)
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", OnDragUpdate)
        GameTooltip:Hide()
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        ns.Persist()
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("SoulSource", 0.58, 0.51, 0.79)
        GameTooltip:AddLine(string.format("%d soul%s captured", db.shardCount, db.shardCount == 1 and "" or "s"), 1, 1, 1)
        GameTooltip:AddLine("Left-click: options", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Right-click: shard list", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end

function ns.UpdateMinimapButton()
    if not db then return end
    if db.minimap.hide then
        if button then button:Hide() end
        return
    end
    button = button or CreateButton()
    UpdatePosition()
    button:Show()
end

table.insert(ns.loginHandlers, function(savedDB)
    db = savedDB
    ns.UpdateMinimapButton()
end)
