-- SoulSource tutorial: a short paged walkthrough, opened from the options
-- window or with /shards tutorial. It never opens by itself.

local ADDON_NAME, ns = ...

local frame
local page = 1

local PAGES = {
    {
        title = "Welcome to SoulSource",
        icon = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02",
        text = "SoulSource remembers whose soul is trapped inside every Soul Shard you make.\n\n" ..
            "This quick tour shows you what it does. You can open it any time from the " ..
            "options window (/soulsource) or with /shards tutorial.",
    },
    {
        title = "Capturing souls",
        icon = "Interface\\Icons\\Spell_Shadow_Haunting",
        text = "Cast Drain Soul on an enemy and make sure it dies while Drain Soul is channeling. " ..
            "When the Soul Shard appears, SoulSource records the victim, its level and type, " ..
            "and where you were.\n\n" ..
            "Every soul gets a number that counts up for your character's whole life: #1, #2, #3...",
    },
    {
        title = "Seeing your souls",
        icon = "Interface\\Icons\\INV_Misc_Bag_10",
        text = "Hover a Soul Shard in your bags or bank to see its number and soul in the tooltip.\n\n" ..
            "Type /shards or right-click the minimap button to open the shard list, which shows " ..
            "every shard you carry, where it came from, and which bag slot it is in.\n\n" ..
            "Shards keep their souls when you move them around.",
    },
    {
        title = "Consuming shards",
        icon = "Interface\\Icons\\INV_Stone_04",
        text = "When a spell uses up a shard (summoning a demon, Shadowburn, Soul Fire...), your " ..
            "character says it in /say, for example:\n" ..
            "|cffffffff\"Soul Shard #42 consumed by Summon Voidwalker: the soul of Defias Pillager, " ..
            "taken in Westfall.\"|r\n\n" ..
            "A Healthstone (cookie) or Soulstone keeps its shard's soul instead. When you trade it to " ..
            "someone, or use a Soulstone on them, they get a whisper telling them whose soul it holds.",
    },
    {
        title = "Lucky numbers",
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        text = "Some shard numbers deserve a shout-out in /say when they are made:\n\n" ..
            "|cffffffff#69|r and |cffffffff#420|r: Nice\n" ..
            "|cffffffff#69420|r and |cffffffff#42069|r: Very Nice\n" ..
            "Repeated last digits: Dubs! (#77), Trips! (#1333), Quads!, Quints!...\n\n" ..
            "Not your thing? Untick \"/say lucky shard numbers\" in the options.",
    },
    {
        title = "Settings",
        icon = "Interface\\Icons\\INV_Misc_Gear_01",
        text = "Type /soulsource or left-click the minimap button to open the options, where you can " ..
            "switch each announcement, the tooltip and the minimap button on or off.\n\n" ..
            "Drag the minimap button to move it. Type /shards help to see every chat command.\n\n" ..
            "Happy hunting!",
    },
}

local function ShowPage()
    local p = PAGES[page]
    frame.icon:SetTexture(p.icon)
    frame.heading:SetText(p.title)
    frame.body:SetText(p.text)
    frame.counter:SetText(page .. " / " .. #PAGES)
    frame.prev:SetEnabled(page > 1)
    frame.next:SetText(page == #PAGES and "Done" or "Next")
end

local function Finish()
    frame:Hide()
end

local function CreateTutorialFrame()
    local ok, f = pcall(CreateFrame, "Frame", "SoulSourceTutorialFrame", UIParent, "BasicFrameTemplateWithInset")
    if not ok then
        f = CreateFrame("Frame", "SoulSourceTutorialFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)
    end
    f:SetSize(420, 320)
    f:SetPoint("CENTER", 0, 60)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "SoulSourceTutorialFrame")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -6)
    title:SetText("SoulSource Tutorial")

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(40, 40)
    f.icon:SetPoint("TOPLEFT", 22, -38)

    f.heading = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.heading:SetPoint("LEFT", f.icon, "RIGHT", 12, 0)

    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.body:SetPoint("TOPLEFT", f.icon, "BOTTOMLEFT", 0, -14)
    f.body:SetPoint("RIGHT", f, "RIGHT", -22, 0)
    f.body:SetJustifyH("LEFT")
    f.body:SetJustifyV("TOP")
    f.body:SetSpacing(2)

    f.prev = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.prev:SetSize(90, 24)
    f.prev:SetPoint("BOTTOMLEFT", 20, 16)
    f.prev:SetText("Back")
    f.prev:SetScript("OnClick", function()
        page = math.max(1, page - 1)
        ShowPage()
    end)

    f.next = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.next:SetSize(90, 24)
    f.next:SetPoint("BOTTOMRIGHT", -20, 16)
    f.next:SetScript("OnClick", function()
        if page == #PAGES then
            Finish()
        else
            page = page + 1
            ShowPage()
        end
    end)

    f.counter = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.counter:SetPoint("BOTTOM", 0, 22)
    return f
end

function ns.ShowTutorial()
    frame = frame or CreateTutorialFrame()
    page = 1
    ShowPage()
    frame:Show()
end

