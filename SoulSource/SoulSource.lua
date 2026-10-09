-- SoulSource: remembers which creature (or player) each Soul Shard came from.
--
-- Runs on WoW: Forever (interface 16001, a modern Retail-engine client) and on
-- Classic Era. Forever blocks the combat log for addons, so nothing here uses it.
--
-- How it works
--   1. When we start channeling Drain Soul we take a snapshot of our target.
--   2. Soul Shards do not stack, so every shard lives in its own bag slot. After
--      every bag update we diff the set of slots holding a shard against the
--      slots we already know about:
--        * a new slot when a shard also vanished elsewhere = the shard was moved
--        * a genuinely new slot = a fresh shard, which only Drain Soul makes, so
--          it gets the soul of the target we were draining (or our dead target)
--        * a vanished slot with no replacement = the shard was used up
--   3. Tooltips for bag/bank slots and the /shards window read those records.
--   4. Every captured soul gets a lifetime number for the character. When a
--      shard is used up by a spell we announce its number, victim and location
--      in /say, and lucky numbers (69, 420, dubs, trips...) get a shout-out.

local ADDON_NAME, ns = ...

local SHARD_ITEM_ID = 6265
local SHARD_NAME_FALLBACK = "Soul Shard"
local DRAIN_SOUL_SPELL_IDS = { 1120, 8288, 8289, 11675, 198590 }
local DRAIN_SOUL_NAME_FALLBACK = "Drain Soul"
local DRAIN_GRACE = 3     -- seconds after Drain Soul stops that a new shard still belongs to its target
local CONSUME_WINDOW = 3  -- seconds between a spell cast and a shard vanishing for it to count as consumed
local HISTORY_MAX = 100

local CHAT_PREFIX = "|cff9482c9SoulSource|r: "
local SOUL_COLOR = "|cffb48ef0"
local GRAY = "|cff9d9d9d"

local GetContainerNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local GetContainerItemID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
local GetContainerItemLink = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
local GetSpellName = (C_Spell and C_Spell.GetSpellName) or function(id)
    return GetSpellInfo and (GetSpellInfo(id))
end
local GetItemNameByID = (C_Item and C_Item.GetItemNameByID) or function(id)
    return GetItemInfo and (GetItemInfo(id))
end

local db                 -- SoulSourceCharDB
local drain              -- { victim = info, active = bool, stoppedAt = GetTime() } for our latest Drain Soul
local bankOpen = false
local bagsReady = false
local lastCast           -- { at = GetTime(), name = spell name } for the player's latest successful cast
local sayQueue = {}      -- /say messages waiting for a key press or click

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

-- Forever (like Retail since Midnight) can hand addons "secret" values that
-- throw when compared or concatenated. Treat them as unknown.
local function Plain(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function SafeCall(fn, ...)
    if not fn then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then return nil end
    return Plain(a), Plain(b), Plain(c)
end

local drainSoulIDs, drainSoulNames = {}, { [DRAIN_SOUL_NAME_FALLBACK] = true }
for _, id in ipairs(DRAIN_SOUL_SPELL_IDS) do
    drainSoulIDs[id] = true
    local name = SafeCall(GetSpellName, id)
    if name then drainSoulNames[name] = true end
end

local function IsDrainSoul(spellID, spellName)
    spellID, spellName = Plain(spellID), Plain(spellName)
    if spellID and drainSoulIDs[spellID] then return true end
    if not spellName and spellID then spellName = SafeCall(GetSpellName, spellID) end
    return spellName ~= nil and drainSoulNames[spellName] == true
end

-- Soul Shards are found by item ID, or by name in case Forever uses a new item.
local shardItemIDs = { [SHARD_ITEM_ID] = true }
local notShardIDs = {}
local shardNames = { [SHARD_NAME_FALLBACK] = true }
do
    local name = SafeCall(GetItemNameByID, SHARD_ITEM_ID)
    if name then shardNames[name] = true end
end

local function IsShardSlot(bag, slot)
    local itemID = SafeCall(GetContainerItemID, bag, slot)
    if not itemID then return false end
    if shardItemIDs[itemID] then return true end
    if notShardIDs[itemID] then return false end
    local link = SafeCall(GetContainerItemLink, bag, slot)
    local name = link and link:match("%[(.-)%]")
    if not name then return false end -- item not cached yet; ask again next scan
    if shardNames[name] then
        shardItemIDs[itemID] = true
        return true
    end
    notShardIDs[itemID] = true
    return false
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(CHAT_PREFIX .. msg)
end

local function SlotKey(bag, slot)
    return bag .. ":" .. slot
end

local function ParseKey(key)
    local bag, slot = key:match("^(-?%d+):(%d+)$")
    return tonumber(bag), tonumber(slot)
end

local function FormatAge(seconds)
    seconds = math.max(0, seconds or 0)
    if seconds < 60 then return "just now" end
    local d = math.floor(seconds / 86400)
    local h = math.floor((seconds % 86400) / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if d > 0 then return string.format("%dd %dh ago", d, h) end
    if h > 0 then return string.format("%dh %dm ago", h, m) end
    return string.format("%dm ago", m)
end

local function ColoredName(rec)
    if rec.isPlayer and rec.class and rec.name then
        local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS or {})[rec.class]
        if c then
            return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, rec.name)
        end
    end
    return SOUL_COLOR .. (rec.name or "an unknown victim") .. "|r"
end

local function NumberTag(rec)
    return rec.number and ("#" .. rec.number .. " ") or ""
end

local CLASSIFICATION_TEXT = {
    elite = "Elite",
    rareelite = "Rare Elite",
    rare = "Rare",
    worldboss = "Boss",
}

-- e.g. "Level 17 Elite Humanoid" or "Level 60 Human Warrior (Player)"
local function Description(rec)
    local parts = {}
    if rec.level then
        parts[#parts + 1] = (rec.level > 0) and ("Level " .. rec.level) or "Level ??"
    end
    if rec.isPlayer then
        if rec.race then parts[#parts + 1] = rec.race end
        if rec.className then parts[#parts + 1] = rec.className end
        parts[#parts + 1] = "(Player)"
    else
        local cls = rec.classification and CLASSIFICATION_TEXT[rec.classification]
        if cls then parts[#parts + 1] = cls end
        if rec.creatureType then parts[#parts + 1] = rec.creatureType end
    end
    return table.concat(parts, " ")
end

local function Location(rec)
    if rec.subzone and rec.subzone ~= "" and rec.subzone ~= rec.zone then
        return (rec.zone or "?") .. " - " .. rec.subzone
    end
    return rec.zone or "Unknown location"
end

-------------------------------------------------------------------------------
-- Containers: Forever uses modern bag IDs (a reagent slot that holds the soul
-- bag, and bank tabs); Classic Era uses the old numbering.
-------------------------------------------------------------------------------

local carriedBags, bankBags, bagLabels = {}, {}, {}
do
    local B = Enum and Enum.BagIndex
    if B and B.Backpack then
        for i = 0, 4 do carriedBags[#carriedBags + 1] = i end
        if B.ReagentBag then
            carriedBags[#carriedBags + 1] = B.ReagentBag
            bagLabels[B.ReagentBag] = "Reagent bag"
        end
        for i = 1, 6 do
            local tab = B["CharacterBankTab_" .. i]
            if tab then
                bankBags[#bankBags + 1] = tab
                bagLabels[tab] = "Bank tab " .. i
            end
        end
        if #bankBags == 0 and B.Bank then
            bankBags[#bankBags + 1] = B.Bank
            bagLabels[B.Bank] = "Bank"
            for i = 1, 7 do
                local bag = B["BankBag_" .. i]
                if bag then
                    bankBags[#bankBags + 1] = bag
                    bagLabels[bag] = "Bank bag " .. i
                end
            end
        end
    else
        local numBags = NUM_BAG_SLOTS or 4
        for i = 0, numBags do carriedBags[#carriedBags + 1] = i end
        local bank = BANK_CONTAINER or -1
        bankBags[#bankBags + 1] = bank
        bagLabels[bank] = "Bank"
        for i = 1, NUM_BANKBAGSLOTS or 6 do
            bankBags[#bankBags + 1] = numBags + i
            bagLabels[numBags + i] = "Bank bag " .. i
        end
    end
    bagLabels[0] = "Backpack"
end
local BANK_ID = BANK_CONTAINER or -1

local function SlotLabel(key)
    local bag, slot = ParseKey(key)
    return string.format("%s, slot %d", bagLabels[bag] or ("Bag " .. bag), slot)
end

-------------------------------------------------------------------------------
-- Victim tracking (Drain Soul channel)
-------------------------------------------------------------------------------

local function DescribeUnit(unit)
    if not SafeCall(UnitExists, unit) then return nil end
    local info = {
        guid = SafeCall(UnitGUID, unit),
        name = SafeCall(UnitName, unit),
        level = SafeCall(UnitLevel, unit),
        classification = SafeCall(UnitClassification, unit),
        creatureType = SafeCall(UnitCreatureType, unit),
    }
    if SafeCall(UnitIsPlayer, unit) then
        info.isPlayer = true
        info.className, info.class = SafeCall(UnitClass, unit)
        info.race = SafeCall(UnitRace, unit)
    end
    if not info.name then return nil end
    return info
end

local function OnChannelStart(spellID)
    local name
    if not Plain(spellID) then
        name = SafeCall(UnitChannelInfo, "player")
    end
    if not IsDrainSoul(spellID, name) then return end
    drain = { victim = DescribeUnit("target"), active = true }
end

local function OnChannelStop()
    if not drain or not drain.active then return end
    drain.active = false
    drain.stoppedAt = GetTime()
    -- Fill in anything we could not read when the channel started.
    local victim = drain.victim
    local now = DescribeUnit("target")
    if now and (not victim or (victim.guid and victim.guid == now.guid) or (not victim.guid and victim.name == now.name)) then
        for k, v in pairs(now) do
            if victim and victim[k] == nil then victim[k] = v end
        end
        drain.victim = victim or now
    end
end

-- Whose soul is the shard that just appeared? nil when nothing suggests a
-- Drain Soul kill (a shard from the mailbox or a trade, for example).
local function TakeVictim()
    local victim
    if drain and (drain.active or GetTime() - (drain.stoppedAt or 0) <= DRAIN_GRACE) then
        victim = drain.victim or {}
        drain = nil
    elseif SafeCall(UnitIsDead, "target") then
        victim = DescribeUnit("target") or {}
    else
        return nil
    end
    victim.time = time()
    victim.zone = SafeCall(GetRealZoneText)
    victim.subzone = SafeCall(GetSubZoneText)
    return victim
end

-------------------------------------------------------------------------------
-- Shard bookkeeping (bag scanning)
-------------------------------------------------------------------------------

local function ContainersToScan()
    local list = {}
    for _, bag in ipairs(carriedBags) do list[#list + 1] = bag end
    if bankOpen then
        for _, bag in ipairs(bankBags) do list[#list + 1] = bag end
    end
    return list
end

local function MakeRecord(victim)
    return {
        name = victim.name,
        level = victim.level,
        classification = victim.classification,
        creatureType = victim.creatureType,
        isPlayer = victim.isPlayer or nil,
        class = victim.class,
        className = victim.className,
        race = victim.race,
        zone = victim.zone,
        subzone = victim.subzone,
        time = victim.time,
    }
end

-------------------------------------------------------------------------------
-- /say announcements
-------------------------------------------------------------------------------

local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

local function ChatLocked()
    return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and SafeCall(C_ChatInfo.InChatMessagingLockdown) or false
end

-- Outside instances the game only lets addons /say during a key press or
-- mouse click, so messages wait in a queue until the player's next input.
-- Forever can also lock addon chat entirely (e.g. during boss fights); the
-- queue simply waits that out.
local function FlushSay()
    if #sayQueue == 0 or ChatLocked() then return end
    for _, msg in ipairs(sayQueue) do
        pcall(SendChat, msg, "SAY")
    end
    wipe(sayQueue)
end

local function QueueSay(msg)
    sayQueue[#sayQueue + 1] = msg
    if SafeCall(IsInInstance) then FlushSay() end
end

local inputFrame
local function HookPlayerInput()
    if not inputFrame then
        inputFrame = CreateFrame("Frame", nil, UIParent)
        inputFrame:SetScript("OnKeyDown", FlushSay)
        WorldFrame:HookScript("OnMouseDown", FlushSay)
        if UseAction then hooksecurefunc("UseAction", FlushSay) end
    end
    -- Keyboard propagation can't be changed in combat; retried on PLAYER_REGEN_ENABLED.
    if InCombatLockdown() then return false end
    inputFrame:EnableKeyboard(true)
    if inputFrame.SetPropagateKeyboardInput then pcall(inputFrame.SetPropagateKeyboardInput, inputFrame, true) end
    return true
end

local function AnnounceConsumed(rec, spellName)
    if rec.unknown then return end
    local where = Location(rec)
    local msg
    if rec.number then
        msg = string.format("Soul Shard #%d consumed by %s: the soul of %s, taken in %s.",
            rec.number, spellName, rec.name or "an unknown victim", where)
    else
        msg = string.format("Soul Shard consumed by %s: the soul of %s, taken in %s.",
            spellName, rec.name or "an unknown victim", where)
    end
    if db.say then QueueSay(msg) else Print(msg) end
end

local function MarkUsed(rec, spellName)
    -- Saved variables don't keep shared table references, so find the
    -- matching history entry instead of relying on rec being the same table.
    for _, h in ipairs(db.history) do
        if h.time == rec.time and h.name == rec.name and not h.usedAt then
            h.usedAt = time()
            h.usedFor = spellName
            break
        end
    end
end

-- A shard that vanishes right before or after one of our casts was consumed by
-- it; otherwise it was deleted, sold or traded and is dropped quietly. The cast
-- event can arrive just after the bag update, so decide a moment later.
local function OnShardGone(rec)
    local goneAt = GetTime()
    C_Timer.After(0.5, function()
        local cast = lastCast
        if cast and math.abs(cast.at - goneAt) <= CONSUME_WINDOW then
            if not rec.unknown then MarkUsed(rec, cast.name) end
            AnnounceConsumed(rec, cast.name)
        end
    end)
end

local function AddHistory(rec)
    if rec.unknown then return end
    table.insert(db.history, 1, rec)
    while #db.history > HISTORY_MAX do table.remove(db.history) end
end

local VERY_NICE_NUMBERS = { [69420] = true, [42069] = true }
local NICE_NUMBERS = { [69] = true, [420] = true }
local REPEAT_NAMES = { "Dubs", "Trips", "Quads", "Quints", "Sexts", "Septs", "Octs", "Nons", "Decs" }

-- "Very Nice", "Nice", or "Dubs!"/"Trips!"/... when the number ends in a run
-- of the same digit (77 -> Dubs, 1333 -> Trips). nil for ordinary numbers.
local function MilestoneMessage(number)
    if not number then return end
    if VERY_NICE_NUMBERS[number] then return "Very Nice" end
    if NICE_NUMBERS[number] then return "Nice" end
    local digits = tostring(number)
    local last, run = digits:sub(-1), 1
    while run < #digits and digits:sub(-run - 1, -run - 1) == last do run = run + 1 end
    if run < 2 then return end
    return (REPEAT_NAMES[run - 1] or (run .. " of a kind")) .. "!"
end

local function AnnounceMilestone(rec)
    if not db.milestones then return end
    local msg = MilestoneMessage(rec.number)
    if msg then QueueSay(msg) end
end

local function AnnounceCapture(rec)
    AnnounceMilestone(rec)
    if not db.announce then return end
    local desc = Description(rec)
    Print(string.format("Captured soul %sof %s%s in %s.",
        NumberTag(rec), ColoredName(rec), desc ~= "" and (" (" .. desc .. ")") or "", Location(rec)))
end

local UpdateWindow -- defined below

local firstScanDone = false

local function ScanBags()
    -- Bag contents are not available for a moment after login; scanning then
    -- would make every known shard look "used".
    if not bagsReady or (SafeCall(GetContainerNumSlots, 0) or 0) == 0 then return false end

    local scanned, present = {}, {}
    for _, bag in ipairs(ContainersToScan()) do
        scanned[bag] = true
        for slot = 1, SafeCall(GetContainerNumSlots, bag) or 0 do
            if IsShardSlot(bag, slot) then
                present[SlotKey(bag, slot)] = true
            end
        end
    end

    local removed, added = {}, {}
    for key in pairs(db.shards) do
        local bag = ParseKey(key)
        if bag and scanned[bag] and not present[key] then removed[#removed + 1] = key end
    end
    for key in pairs(present) do
        if not db.shards[key] then added[#added + 1] = key end
    end
    if #removed == 0 and #added == 0 then return true end
    table.sort(removed)
    table.sort(added)

    -- Shards appearing beyond the number that vanished are new. The very first
    -- scan after login only finds shards we have no record of, so those are
    -- "unknown" rather than fresh captures.
    local fresh = #added - #removed
    local changed = false
    while fresh > 0 and #added > 0 do
        local victim = firstScanDone and TakeVictim()
        local rec
        if victim then
            rec = MakeRecord(victim)
            db.shardCount = db.shardCount + 1
            rec.number = db.shardCount
            db.stats.total = db.stats.total + 1
            db.stats.byName[rec.name or "?"] = (db.stats.byName[rec.name or "?"] or 0) + 1
            AddHistory(rec)
            AnnounceCapture(rec)
            ns.Persist()
        else
            rec = { unknown = true }
        end
        db.shards[table.remove(added, 1)] = rec
        fresh = fresh - 1
        changed = true
    end

    -- The rest are moves (pair vanished slots with new slots) or shards used up.
    for _, key in ipairs(removed) do
        local rec = db.shards[key]
        db.shards[key] = nil
        local dest = table.remove(added, 1)
        if dest then
            db.shards[dest] = rec
        else
            OnShardGone(rec)
        end
        changed = true
    end

    if changed and UpdateWindow then UpdateWindow() end
    return true
end

local function FirstScan()
    bagsReady = true
    if ScanBags() then
        firstScanDone = true
    else
        C_Timer.After(2, FirstScan)
    end
end

-------------------------------------------------------------------------------
-- Tooltips
-------------------------------------------------------------------------------

local function AddShardLines(tooltip, key)
    local rec = db and db.tooltip and db.shards[key]
    if not rec then return end
    if rec.unknown then
        tooltip:AddLine("Soul origin unknown", 0.6, 0.6, 0.6)
        tooltip:AddLine("(SoulSource has no record of this shard)", 0.6, 0.6, 0.6)
    else
        tooltip:AddLine(NumberTag(rec) .. "Soul of " .. ColoredName(rec), 1, 1, 1)
        local desc = Description(rec)
        if desc ~= "" then tooltip:AddLine(desc, 0.85, 0.85, 0.85) end
        tooltip:AddLine(Location(rec), 0.85, 0.85, 0.85)
        if rec.time then
            tooltip:AddLine("Captured " .. FormatAge(time() - rec.time), 0.6, 0.6, 0.6)
        end
    end
    tooltip:Show()
end

local function HookTooltips()
    if GameTooltip.SetBagItem then
        hooksecurefunc(GameTooltip, "SetBagItem", function(tooltip, bag, slot)
            AddShardLines(tooltip, SlotKey(bag, slot))
        end)
    end
    -- Classic's main bank slots are shown through SetInventoryItem.
    if not (GameTooltip.SetInventoryItem and BankButtonIDToInvSlotID) then return end
    hooksecurefunc(GameTooltip, "SetInventoryItem", function(tooltip, unit, invSlot)
        if unit ~= "player" then return end
        for slot = 1, SafeCall(GetContainerNumSlots, BANK_ID) or 0 do
            if BankButtonIDToInvSlotID(slot) == invSlot then
                AddShardLines(tooltip, SlotKey(BANK_ID, slot))
                return
            end
        end
    end)
end

-------------------------------------------------------------------------------
-- /shards window
-------------------------------------------------------------------------------

local window
local ROW_HEIGHT = 34
local SHARD_ICON = "Interface\\Icons\\INV_Misc_Gem_Amethyst_02"

local function CreateWindow()
    local ok, f = pcall(CreateFrame, "Frame", "SoulSourceFrame", UIParent, "BasicFrameTemplateWithInset")
    if not ok then
        f = CreateFrame("Frame", "SoulSourceFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)
    end
    f:SetSize(400, 360)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, "SoulSourceFrame") -- close with Escape

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -6)
    title:SetText("SoulSource - Soul Shards")

    local scroll = CreateFrame("ScrollFrame", "SoulSourceScrollFrame", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -32)
    scroll:SetPoint("BOTTOMRIGHT", -34, 34)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(350, 1)
    scroll:SetScrollChild(content)
    f.content = content
    f.rows = {}

    f.empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOPLEFT", 4, -8)
    f.empty:SetText("No Soul Shards in your bags.")

    f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.summary:SetPoint("BOTTOMLEFT", 16, 14)
    f.summary:SetPoint("BOTTOMRIGHT", -16, 14)
    f.summary:SetJustifyH("LEFT")

    f.elapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed > 30 then UpdateWindow() end -- keep "x minutes ago" fresh
    end)
    f:SetScript("OnShow", function() UpdateWindow() end)
    return f
end

local function GetRow(index)
    local row = window.rows[index]
    if row then return row end
    row = CreateFrame("Frame", nil, window.content)
    row:SetSize(350, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(26, 26)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:SetTexture(SHARD_ICON)
    row.line1 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.line1:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 0)
    row.line1:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.line1:SetJustifyH("LEFT")
    row.line1:SetWordWrap(false)
    row.line2 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.line2:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 0)
    row.line2:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.line2:SetJustifyH("LEFT")
    row.line2:SetWordWrap(false)
    window.rows[index] = row
    return row
end

local function SortedShards()
    local list = {}
    for key, rec in pairs(db.shards) do list[#list + 1] = { key = key, rec = rec } end
    table.sort(list, function(a, b)
        local ta, tb = a.rec.time or 0, b.rec.time or 0
        if ta ~= tb then return ta > tb end
        return a.key < b.key
    end)
    return list
end

function UpdateWindow()
    if not window or not window:IsShown() then return end
    window.elapsed = 0
    local list = SortedShards()
    local now = time()
    for i, entry in ipairs(list) do
        local row, rec = GetRow(i), entry.rec
        if rec.unknown then
            row.line1:SetText(GRAY .. "Unknown soul|r")
            row.line2:SetText(GRAY .. SlotLabel(entry.key) .. " - no record of where it came from|r")
        else
            local desc = Description(rec)
            row.line1:SetText(NumberTag(rec) .. ColoredName(rec) .. (desc ~= "" and (GRAY .. "  " .. desc .. "|r") or ""))
            row.line2:SetText(GRAY .. Location(rec) .. " - " .. FormatAge(now - (rec.time or now)) ..
                " - " .. SlotLabel(entry.key) .. "|r")
        end
        row:Show()
    end
    for i = #list + 1, #window.rows do window.rows[i]:Hide() end
    window.empty:SetShown(#list == 0)
    window.content:SetHeight(math.max(1, #list * ROW_HEIGHT))
    window.summary:SetText(string.format("%d shard%s held  |  %d soul%s captured in this character's life",
        #list, #list == 1 and "" or "s", db.shardCount, db.shardCount == 1 and "" or "s"))
end

local function ToggleWindow()
    window = window or CreateWindow()
    window:SetShown(not window:IsShown())
end

local function ResetStats()
    db.stats = { total = 0, byName = {} }
    db.history = {}
    Print("Statistics and history cleared (shards keep their souls, and shard numbering continues).")
    UpdateWindow()
    ns.Persist()
end

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function PrintList()
    local list = SortedShards()
    if #list == 0 then
        Print("You are not carrying any Soul Shards.")
        return
    end
    Print(#list .. " Soul Shard(s):")
    local now = time()
    for _, entry in ipairs(list) do
        local rec = entry.rec
        if rec.unknown then
            DEFAULT_CHAT_FRAME:AddMessage("  " .. GRAY .. "Unknown soul - " .. SlotLabel(entry.key) .. "|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s%s %s(%s, %s, %s)|r", NumberTag(rec), ColoredName(rec), GRAY,
                Description(rec), Location(rec), FormatAge(now - (rec.time or now))))
        end
    end
end

local function PrintStats()
    Print(string.format("%d soul(s) captured in this character's life.", db.shardCount))
    if db.stats.total ~= db.shardCount then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %d since the last /shards reset:", db.stats.total))
    end
    local top = {}
    for name, count in pairs(db.stats.byName) do top[#top + 1] = { name = name, count = count } end
    table.sort(top, function(a, b) return a.count > b.count or (a.count == b.count and a.name < b.name) end)
    for i = 1, math.min(10, #top) do
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %2d. %s%s|r x%d", i, SOUL_COLOR, top[i].name, top[i].count))
    end
end

local function PrintHistory()
    if #db.history == 0 then
        Print("No captured souls recorded yet.")
        return
    end
    Print("Most recent captured souls:")
    local now = time()
    for i = 1, math.min(15, #db.history) do
        local rec = db.history[i]
        local used = rec.usedAt and (" - used " .. (rec.usedFor and ("for " .. rec.usedFor .. " ") or "") ..
            FormatAge(now - rec.usedAt)) or ""
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s%s %s(%s, %s%s)|r", NumberTag(rec), ColoredName(rec), GRAY,
            Location(rec), FormatAge(now - (rec.time or now)), used))
    end
end

SLASH_SOULSOURCESHARDS1 = "/shards"
SlashCmdList.SOULSOURCESHARDS = function(msg)
    local cmd = strtrim(msg or ""):lower()
    if cmd == "" or cmd == "show" then
        ToggleWindow()
    elseif cmd == "options" or cmd == "config" then
        ns.ToggleOptions()
    elseif cmd == "tutorial" then
        ns.ShowTutorial()
    elseif cmd == "list" then
        PrintList()
    elseif cmd == "stats" then
        PrintStats()
    elseif cmd == "history" then
        PrintHistory()
    elseif cmd == "announce" then
        db.announce = not db.announce
        Print("Capture announcements " .. (db.announce and "enabled." or "disabled."))
        ns.RefreshOptions()
        ns.Persist()
    elseif cmd == "say" then
        db.say = not db.say
        Print("Consumed shards are now announced " .. (db.say and "in /say." or "only to you."))
        ns.RefreshOptions()
        ns.Persist()
    elseif cmd == "lucky" then
        db.milestones = not db.milestones
        Print("Lucky number shout-outs (Nice, Dubs!...) " .. (db.milestones and "enabled." or "disabled."))
        ns.RefreshOptions()
        ns.Persist()
    elseif cmd == "reset" then
        ResetStats()
    else
        Print("commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /soulsource - open the options window")
        DEFAULT_CHAT_FRAME:AddMessage("  /shards - toggle the Soul Shard window")
        DEFAULT_CHAT_FRAME:AddMessage("  /shards tutorial - show the tutorial again")
        DEFAULT_CHAT_FRAME:AddMessage("  /shards list - print every shard and its soul")
        DEFAULT_CHAT_FRAME:AddMessage("  /shards history - recently captured souls")
        DEFAULT_CHAT_FRAME:AddMessage("  /shards stats - most-captured souls")
        DEFAULT_CHAT_FRAME:AddMessage("  /shards announce - toggle the chat message on capture")
        DEFAULT_CHAT_FRAME:AddMessage("  /shards say - toggle announcing consumed shards in /say")
        DEFAULT_CHAT_FRAME:AddMessage("  /shards lucky - toggle Nice / Very Nice / Dubs! shout-outs")
        DEFAULT_CHAT_FRAME:AddMessage("  /shards reset - clear statistics and history")
    end
end

-------------------------------------------------------------------------------
-- Shared with Options.lua, Minimap.lua and Tutorial.lua
-------------------------------------------------------------------------------

ns.Print = Print
ns.ToggleWindow = ToggleWindow
ns.ResetStats = ResetStats
ns.SHARD_ICON = SHARD_ICON
ns.loginHandlers = {}           -- UI files add function(db) callbacks, run at PLAYER_LOGIN
ns.RefreshOptions = function() end -- replaced by Options.lua
ns.Persist = function() end        -- replaced by Persist.lua
ns.OnCombatEnded = function() end  -- replaced by Persist.lua
ns.MacroBackupActive = function() return false end -- replaced by Persist.lua
ns.UpdateMinimapButton = function() end           -- replaced by Minimap.lua

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
-- Registering an event the client doesn't know throws on Forever, so try each.
for _, event in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED",
    "BAG_UPDATE_DELAYED", "PLAYERBANKSLOTS_CHANGED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
    "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
}) do
    pcall(events.RegisterEvent, events, event)
end
for _, event in ipairs({ "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_SUCCEEDED" }) do
    if not (events.RegisterUnitEvent and pcall(events.RegisterUnitEvent, events, event, "player")) then
        pcall(events.RegisterEvent, events, event)
    end
end

local BANKER = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Banker
local inputHooked = false

local function SetBankOpen(open)
    bankOpen = open
    if open then ScanBags() end
end

events:SetScript("OnEvent", function(_, event, arg1, _, arg3)
    if event == "UNIT_SPELLCAST_CHANNEL_START" then
        if arg1 == "player" then OnChannelStart(arg3) end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if arg1 == "player" then OnChannelStop() end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 == "player" then
            local id = Plain(arg3)
            lastCast = { at = GetTime(), name = (id and SafeCall(GetSpellName, id)) or "a spell" }
        end
    elseif event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        ns.hadSavedVariables = SoulSourceCharDB ~= nil
        SoulSourceCharDB = SoulSourceCharDB or {}
        db = SoulSourceCharDB
        db.shards = db.shards or {}
        db.history = db.history or {}
        db.stats = db.stats or { total = 0, byName = {} }
        if db.announce == nil then db.announce = true end
        if db.say == nil then db.say = true end
        if db.milestones == nil then db.milestones = true end
        if db.tooltip == nil then db.tooltip = true end
        db.minimap = db.minimap or { angle = 200, hide = false }
        -- Lifetime shard counter; never cleared by /shards reset.
        db.shardCount = db.shardCount or db.stats.total
    elseif event == "PLAYER_LOGIN" then
        HookTooltips()
        inputHooked = HookPlayerInput()
        for _, init in ipairs(ns.loginHandlers) do init(db) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if not inputHooked then inputHooked = HookPlayerInput() end
        ns.OnCombatEnded()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not bagsReady then C_Timer.After(2, FirstScan) end
    elseif event == "BANKFRAME_OPENED" then
        SetBankOpen(true)
    elseif event == "BANKFRAME_CLOSED" then
        SetBankOpen(false)
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if BANKER and arg1 == BANKER then SetBankOpen(true) end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if BANKER and arg1 == BANKER then SetBankOpen(false) end
    else -- BAG_UPDATE_DELAYED, PLAYERBANKSLOTS_CHANGED
        ScanBags()
    end
end)
