-- SoulSource options window: opened with /soulsource, the minimap button,
-- or from the game's Interface/AddOns settings.

local ADDON_NAME, ns = ...

local db
local frame

local OPTIONS = {
    {
        key = "announce",
        label = "Announce captured souls in chat",
        tip = "Prints \"Captured soul #12 of Defias Pillager...\" in your chat window (only you see it).",
    },
    {
        key = "tooltip",
        label = "Show the soul in Soul Shard tooltips",
        tip = "Adds the shard number, victim, location and age to the tooltip of each Soul Shard.",
    },
    {
        key = "say",
        label = "/say when a shard is consumed",
        tip = "\"Soul Shard #42 consumed by Summon Voidwalker: the soul of ...\"\n" ..
            "Shards turned into a Healthstone or Soulstone are announced later, to whoever gets the stone.\n" ..
            "When off, only you see the message.",
    },
    {
        key = "stoneWhisper",
        label = "Whisper a Healthstone/Soulstone's soul to whoever gets it",
        tip = "When you trade a Healthstone (cookie) or Soulstone to a player, or use a Soulstone on one, " ..
            "they get a whisper: \"The Healthstone I just gave you holds the soul of Defias Pillager " ..
            "(Soul Shard #42), taken in Westfall.\"\nWhen off, only you see the message.",
    },
    {
        key = "milestones",
        label = "/say lucky shard numbers (Nice, Very Nice, Dubs!...)",
        tip = "#69 and #420: Nice\n#69420 and #42069: Very Nice\nRepeated last digits: Dubs!, Trips!, Quads!...\nWhen off, nothing is said for lucky numbers.",
    },
    {
        key = "minimap",
        label = "Show the minimap button",
        tip = "Left-click opens these options, right-click opens your shard list. Drag it to move it around the minimap.",
        get = function() return not db.minimap.hide end,
        set = function(value)
            db.minimap.hide = not value
            ns.UpdateMinimapButton()
        end,
    },
}

StaticPopupDialogs["SOULSOURCE_RESET"] = {
    text = "Clear SoulSource statistics and capture history?\n\nShards keep their souls and shard numbering continues.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        ns.ResetStats()
        ns.RefreshOptions()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function CreateCheckbox(parent, option, y)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 18, y)
    cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    cb.label:SetText(option.label)
    cb:SetHitRectInsets(0, -cb.label:GetStringWidth() - 4, 0, 0)
    cb.option = option
    cb:SetScript("OnClick", function(self)
        local value = self:GetChecked() and true or false
        if option.set then option.set(value) else db[option.key] = value end
        ns.Persist()
    end)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(option.label, 1, 1, 1)
        GameTooltip:AddLine(option.tip, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", GameTooltip_Hide)
    return cb
end

local function CreateButton(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 24)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function CreateOptionsFrame()
    local ok, f = pcall(CreateFrame, "Frame", "SoulSourceOptionsFrame", UIParent, "BasicFrameTemplateWithInset")
    if not ok then
        f = CreateFrame("Frame", "SoulSourceOptionsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)
    end
    f:SetSize(420, 420)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "SoulSourceOptionsFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -6)
    title:SetText("SoulSource Options")

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(36, 36)
    icon:SetPoint("TOPLEFT", 20, -36)
    icon:SetTexture(ns.SHARD_ICON)

    local heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    heading:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -2)
    heading:SetText("SoulSource")

    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.count:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)

    f.checkboxes = {}
    local y = -86
    for _, option in ipairs(OPTIONS) do
        f.checkboxes[#f.checkboxes + 1] = CreateCheckbox(f, option, y)
        y = y - 32
    end

    local shards = CreateButton(f, "Shard List", 120, function() ns.ToggleWindow() end)
    shards:SetPoint("BOTTOMLEFT", 20, 48)
    local tutorial = CreateButton(f, "Tutorial", 120, function() ns.ShowTutorial() end)
    tutorial:SetPoint("LEFT", shards, "RIGHT", 10, 0)
    local reset = CreateButton(f, "Reset Stats", 120, function() StaticPopup_Show("SOULSOURCE_RESET") end)
    reset:SetPoint("LEFT", tutorial, "RIGHT", 10, 0)

    f.backup = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.backup:SetPoint("BOTTOMLEFT", shards, "TOPLEFT", 0, 10)
    f.backup:SetPoint("RIGHT", f, "RIGHT", -20, 0)
    f.backup:SetJustifyH("LEFT")
    f.backup:SetText("Forever beta: the game forgets addon data on restart, so your shard count and " ..
        "settings are also kept in a character macro named \"SoulSource\". Don't delete it.")

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", 0, 20)
    hint:SetText("/soulsource opens this window  -  /shards opens your shard list")

    f:SetScript("OnShow", function() ns.RefreshOptions() end)
    return f
end

function ns.RefreshOptions()
    if not frame or not frame:IsShown() then return end
    frame.backup:SetShown(ns.MacroBackupActive())
    frame.count:SetText(string.format("%d soul%s captured in this character's life",
        db.shardCount, db.shardCount == 1 and "" or "s"))
    for _, cb in ipairs(frame.checkboxes) do
        local option = cb.option
        local value
        if option.get then value = option.get() else value = db[option.key] end
        cb:SetChecked(value and true or false)
    end
end

function ns.ToggleOptions()
    frame = frame or CreateOptionsFrame()
    frame:SetShown(not frame:IsShown())
end

-- A small page in the game's own settings that points to our window.
local function RegisterBlizzardPanel()
    local panel = CreateFrame("Frame")
    panel.name = "SoulSource"
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("SoulSource")
    local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    text:SetText("Settings live in their own window. You can also open it with /soulsource or the minimap button.")
    local open = CreateButton(panel, "Open SoulSource Options", 200, function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then HideUIPanel(InterfaceOptionsFrame) end
        frame = frame or CreateOptionsFrame()
        frame:Show()
    end)
    open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -12)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

SLASH_SOULSOURCEOPTIONS1 = "/soulsource"
SlashCmdList.SOULSOURCEOPTIONS = function()
    ns.ToggleOptions()
end

table.insert(ns.loginHandlers, function(savedDB)
    db = savedDB
    RegisterBlizzardPanel()
end)
