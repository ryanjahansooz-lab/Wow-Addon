-- SoulSource: remembers which creature (or player) each Soul Shard came from.
--
-- How it works
--   1. The combat log tells us when our Drain Soul is on a target and when that
--      target dies. A death while Drain Soul is ticking (or within a short grace
--      window after it fades, since the aura is removed right before UNIT_DIED)
--      becomes a "pending soul".
--   2. Soul Shards do not stack in Classic, so every shard lives in its own bag
--      slot. After every bag update we diff the set of slots holding a shard
--      against the slots we already know about:
--        * a new slot when a shard also vanished elsewhere = the shard was moved
--        * a genuinely new slot = a fresh shard, so it takes the oldest pending soul
--        * a vanished slot with no replacement = the shard was used up
--   3. Tooltips for bag/bank slots and the /shards window read those records.
--   4. Every captured soul gets a lifetime number for the character. When a
--      shard is used up by a spell we announce its number, victim and location
--      in /say, and lucky numbers (69, 420, dubs, trips...) get a shout-out.

local ADDON_NAME, ns = ...

local SHARD_ITEM_ID = 6265
local DRAIN_SOUL_SPELL_IDS = { 1120, 8288, 8289, 11675 }
local KILL_GRACE = 1.5    -- seconds after Drain Soul fades that a death still counts
local PENDING_TTL = 6     -- seconds a recorded kill waits for its shard to appear
local CONSUME_WINDOW = 3  -- seconds between a spell cast and a shard vanishing for it to count as consumed
local HISTORY_MAX = 100

local CHAT_PREFIX = "|cff9482c9SoulSource|r: "
local SOUL_COLOR = "|cffb48ef0"
local GRAY = "|cff9d9d9d"

local GetContainerNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local GetContainerItemID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
local COMBATLOG_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x00000400
local BANK_ID = BANK_CONTAINER or -1
local NUM_BAGS = NUM_BAG_SLOTS or 4
local NUM_BANK_BAGS = NUM_BANKBAGSLOTS or 6

local db                 -- SoulSourceCharDB
local playerGUID
local drainTargets = {}  -- guid -> victim info while our Drain Soul is (or just was) on it
local pendingSouls = {}  -- victims that died to Drain Soul and are waiting for their shard
local bankOpen = false
local bagsReady = false
local lastCast           -- { at = GetTime(), name = spell name } for the player's latest successful cast
local sayQueue = {}      -- /say messages waiting for a key press or click

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local drainSoulIDs, drainSoulNames = {}, {}
for _, id in ipairs(DRAIN_SOUL_SPELL_IDS) do
    drainSoulIDs[id] = true
    local name = GetSpellInfo and GetSpellInfo(id)
    if name then drainSoulNames[name] = true end
end

-- Classic combat logs may report spellId as 0, so fall back to the localized name.
local function IsDrainSoul(spellId, spellName)
    return drainSoulIDs[spellId] or (spellName and drainSoulNames[spellName]) or false
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

local function IsBankBag(bag)
    return bag == BANK_ID or bag > NUM_BAGS
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
    if rec.isPlayer and rec.class then
        local c = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS or {})[rec.class]
        if c then
            return string.format("|cff%02x%02x%02x%s|r", c.r * 255, c.g * 255, c.b * 255, rec.name)
        end
    end
    return SOUL_COLOR .. (rec.name or UNKNOWN or "Unknown") .. "|r"
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

local function SlotLabel(key)
    local bag, slot = ParseKey(key)
    if bag == BANK_ID then return "Bank slot " .. slot end
    if bag > NUM_BAGS then return string.format("Bank bag %d, slot %d", bag - NUM_BAGS, slot) end
    if bag == 0 then return "Backpack, slot " .. slot end
    return string.format("Bag %d, slot %d", bag, slot)
end

-------------------------------------------------------------------------------
-- Victim tracking (combat log)
-------------------------------------------------------------------------------

local function FindUnitByGUID(guid)
    for _, unit in ipairs({ "target", "mouseover", "focus", "pettarget", "targettarget" }) do
        if UnitExists(unit) and UnitGUID(unit) == guid then return unit end
    end
    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitGUID(unit) == guid then return unit end
    end
end

local function DescribeVictim(guid, name, flags)
    local info = {
        guid = guid,
        name = name,
        isPlayer = bit.band(flags or 0, COMBATLOG_PLAYER) > 0,
    }
    local unit = FindUnitByGUID(guid)
    if unit then
        info.name = UnitName(unit) or name
        info.level = UnitLevel(unit)
        info.classification = UnitClassification(unit)
        info.creatureType = UnitCreatureType(unit)
        if UnitIsPlayer(unit) then
            info.isPlayer = true
            info.className, info.class = UnitClass(unit)
            info.race = UnitRace(unit)
        end
    end
    return info
end

-- Fill in anything we could not see when Drain Soul first landed.
local function RefreshVictim(info)
    if info.level then return end
    local unit = FindUnitByGUID(info.guid)
    if unit then
        local fresh = DescribeVictim(info.guid, info.name, info.isPlayer and COMBATLOG_PLAYER or 0)
        for k, v in pairs(fresh) do info[k] = v end
    end
end

local function OnVictimDied(guid)
    local info = drainTargets[guid]
    if not info then return end
    drainTargets[guid] = nil
    if info.fadedAt and GetTime() - info.fadedAt > KILL_GRACE then return end

    info.fadedAt = nil
    info.time = time()
    info.zone = GetRealZoneText()
    info.subzone = GetSubZoneText()
    info.expires = GetTime() + PENDING_TTL
    pendingSouls[#pendingSouls + 1] = info
end

local function OnCombatLog()
    local _, subevent, _, sourceGUID, _, _, _, destGUID, destName, destFlags, _, spellId, spellName =
        CombatLogGetCurrentEventInfo()

    if subevent == "UNIT_DIED" or subevent == "PARTY_KILL" then
        OnVictimDied(destGUID)
        return
    end

    if sourceGUID ~= playerGUID or not IsDrainSoul(spellId, spellName) then return end

    if subevent == "SPELL_AURA_APPLIED" or subevent == "SPELL_AURA_REFRESH" then
        local info = drainTargets[destGUID]
        if info then
            info.fadedAt = nil
            RefreshVictim(info)
        else
            drainTargets[destGUID] = DescribeVictim(destGUID, destName, destFlags)
        end
    elseif subevent == "SPELL_AURA_REMOVED" then
        local info = drainTargets[destGUID]
        if info then
            RefreshVictim(info)
            info.fadedAt = GetTime()
        end
    end
end

local function PruneStale()
    local now = GetTime()
    for guid, info in pairs(drainTargets) do
        if info.fadedAt and now - info.fadedAt > KILL_GRACE then
            drainTargets[guid] = nil
        end
    end
    for i = #pendingSouls, 1, -1 do
        if pendingSouls[i].expires < now then
            table.remove(pendingSouls, i)
        end
    end
end

-------------------------------------------------------------------------------
-- Shard bookkeeping (bag scanning)
-------------------------------------------------------------------------------

local function ContainersToScan()
    local list = {}
    for bag = 0, NUM_BAGS do list[#list + 1] = bag end
    if bankOpen then
        list[#list + 1] = BANK_ID
        for bag = NUM_BAGS + 1, NUM_BAGS + NUM_BANK_BAGS do list[#list + 1] = bag end
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

-- Outside instances the game only lets addons /say during a key press or
-- mouse click, so messages wait in a queue until the player's next input.
local function FlushSay()
    if #sayQueue == 0 then return end
    for _, msg in ipairs(sayQueue) do
        SendChatMessage(msg, "SAY")
    end
    wipe(sayQueue)
end

local function QueueSay(msg)
    sayQueue[#sayQueue + 1] = msg
    if IsInInstance() then FlushSay() end
end

local inputFrame
local function HookPlayerInput()
    if not inputFrame then
        inputFrame = CreateFrame("Frame", nil, UIParent)
        inputFrame:SetScript("OnKeyDown", FlushSay)
        WorldFrame:HookScript("OnMouseDown", FlushSay)
        hooksecurefunc("UseAction", FlushSay)
    end
    -- Keyboard propagation can't be changed in combat; retried on PLAYER_REGEN_ENABLED.
    if InCombatLockdown() then return false end
    inputFrame:EnableKeyboard(true)
    inputFrame:SetPropagateKeyboardInput(true)
    return true
end

local function AnnounceConsumed(rec, spellName)
    if rec.unknown then return end
    local where = Location(rec)
    local msg
    if rec.number then
        msg = string.format("Soul Shard #%d consumed by %s: the soul of %s, taken in %s.",
            rec.number, spellName, rec.name or "?", where)
    else
        msg = string.format("Soul Shard consumed by %s: the soul of %s, taken in %s.",
            spellName, rec.name or "?", where)
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

local function ScanBags()
    -- Bag contents are not available for a moment after login; scanning then
    -- would make every known shard look "used".
    if not bagsReady or (GetContainerNumSlots(0) or 0) == 0 then return end
    PruneStale()

    local scanned, present = {}, {}
    for _, bag in ipairs(ContainersToScan()) do
        scanned[bag] = true
        for slot = 1, GetContainerNumSlots(bag) or 0 do
            if GetContainerItemID(bag, slot) == SHARD_ITEM_ID then
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
    if #removed == 0 and #added == 0 then return end
    table.sort(removed)
    table.sort(added)

    -- Shards appearing beyond the number that vanished are newly created.
    -- The game puts new loot in the first free slot, so the earliest slots get the souls.
    local fresh = #added - #removed
    local changed = false
    local i = 1
    while fresh > 0 and i <= #added do
        local victim = table.remove(pendingSouls, 1)
        local rec
        if victim then
            rec = MakeRecord(victim)
            db.shardCount = db.shardCount + 1
            rec.number = db.shardCount
            db.stats.total = db.stats.total + 1
            db.stats.byName[rec.name or "?"] = (db.stats.byName[rec.name or "?"] or 0) + 1
            AddHistory(rec)
            AnnounceCapture(rec)
        else
            rec = { unknown = true }
        end
        db.shards[added[i]] = rec
        table.remove(added, i)
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
end

-------------------------------------------------------------------------------
-- Tooltips
-------------------------------------------------------------------------------

local function AddShardLines(tooltip, key)
    local rec = db and db.tooltip and db.shards[key]
    if not rec then return end
    if rec.unknown then
        tooltip:AddLine("Soul origin unknown", 0.6, 0.6, 0.6)
        tooltip:AddLine("(obtained before SoulSource was tracking)", 0.6, 0.6, 0.6)
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
    hooksecurefunc(GameTooltip, "SetBagItem", function(tooltip, bag, slot)
        AddShardLines(tooltip, SlotKey(bag, slot))
    end)
    -- Main bank slots are shown through SetInventoryItem by the default UI.
    hooksecurefunc(GameTooltip, "SetInventoryItem", function(tooltip, unit, invSlot)
        if unit ~= "player" or not BankButtonIDToInvSlotID then return end
        for slot = 1, GetContainerNumSlots(BANK_ID) or 0 do
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
            row.line2:SetText(GRAY .. SlotLabel(entry.key) .. " - obtained before tracking|r")
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
    elseif cmd == "say" then
        db.say = not db.say
        Print("Consumed shards are now announced " .. (db.say and "in /say." or "only to you."))
        ns.RefreshOptions()
    elseif cmd == "lucky" then
        db.milestones = not db.milestones
        Print("Lucky number shout-outs (Nice, Dubs!...) " .. (db.milestones and "enabled." or "disabled."))
        ns.RefreshOptions()
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

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
events:RegisterEvent("BANKFRAME_OPENED")
events:RegisterEvent("BANKFRAME_CLOSED")
events:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")

events:SetScript("OnEvent", function(_, event, arg1, _, arg3)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLog()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 == "player" then
            lastCast = { at = GetTime(), name = (arg3 and GetSpellInfo(arg3)) or "a spell" }
        end
    elseif event == "ADDON_LOADED" and arg1 == ADDON_NAME then
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
        playerGUID = UnitGUID("player")
        HookTooltips()
        if HookPlayerInput() then events:UnregisterEvent("PLAYER_REGEN_ENABLED") end
        for _, init in ipairs(ns.loginHandlers) do init(db) end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if HookPlayerInput() then events:UnregisterEvent("PLAYER_REGEN_ENABLED") end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not bagsReady then
            C_Timer.After(2, function()
                bagsReady = true
                ScanBags()
            end)
        end
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        ScanBags()
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
    else -- BAG_UPDATE_DELAYED, PLAYERBANKSLOTS_CHANGED
        ScanBags()
    end
end)
