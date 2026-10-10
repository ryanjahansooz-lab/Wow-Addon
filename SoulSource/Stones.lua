-- SoulSource stones: a Healthstone ("cookie") or Soulstone made from a Soul
-- Shard remembers that shard's soul. Nothing is said when the stone is made;
-- instead, whoever receives it is told by whisper:
--   * when you trade the stone to another player, or
--   * when you use the stone on another player (Soulstone).
-- Warlock stones are unique, so we keep one soul per kind of stone.

local ADDON_NAME, ns = ...

local db
local Plain, SafeCall

local tradePartner       -- full name of the player in the open trade window
local tradeStones        -- { [kind] = rec } offered in the trade when it was accepted
local castTargets = {}   -- castGUID -> target name from UNIT_SPELLCAST_SENT

local function SoulText(rec)
    local who = rec.name or "an unknown victim"
    local number = rec.number and (" (Soul Shard #" .. rec.number .. ")") or ""
    return string.format("the soul of %s%s, taken in %s", who, number, ns.Location(rec))
end

local function Tell(target, msg)
    if db.stoneWhisper and target then
        ns.QueueWhisper(msg, target)
    else
        ns.Print(msg .. (target and (" (to " .. target .. ")") or ""))
    end
end

function ns.OnStoneCreated(kind, rec)
    if rec.unknown then
        db.stones[kind] = nil
        return
    end
    db.stones[kind] = rec
    if db.announce then
        ns.Print(string.format("Your %s holds %s %s. It will be passed on to whoever you give it to.",
            kind, ns.NumberTag(rec) ~= "" and ("soul " .. ns.NumberTag(rec) .. "of") or "the soul of",
            ns.ColoredName(rec)))
    end
end

-- Forget stones that are no longer in our bags (eaten, used, deleted...).
local function CheckStonesInBags()
    if not next(db.stones) then return end
    local found = {}
    for _, bag in ipairs(ns.CarriedBags) do
        for slot = 1, SafeCall(ns.GetContainerNumSlots, bag) or 0 do
            local link = SafeCall(ns.GetContainerItemLink, bag, slot)
            local kind = link and ns.StoneKind(link:match("%[(.-)%]"))
            if kind then found[kind] = true end
        end
    end
    for kind in pairs(db.stones) do
        if not found[kind] then db.stones[kind] = nil end
    end
end

-------------------------------------------------------------------------------
-- Trades
-------------------------------------------------------------------------------

local function TradePartnerName()
    local name, realm = SafeCall(UnitName, "NPC")
    if not name then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    return name
end

-- Remember which of our stones are in the trade at the moment it's accepted;
-- by the time "Trade complete" arrives they may have left our bags already.
local function SnapshotTrade()
    tradePartner = TradePartnerName() or tradePartner
    tradeStones = {}
    for i = 1, MAX_TRADABLE_ITEMS or 6 do
        local name = SafeCall(GetTradePlayerItemInfo, i)
        local kind = ns.StoneKind(name)
        if kind and db.stones[kind] then tradeStones[kind] = db.stones[kind] end
    end
end

local function OnTradeComplete()
    if not tradeStones or not tradePartner then return end
    for kind, rec in pairs(tradeStones) do
        Tell(tradePartner, string.format("The %s I just gave you holds %s.", kind, SoulText(rec)))
        db.stones[kind] = nil
    end
    tradeStones = nil
end

-------------------------------------------------------------------------------
-- Using a stone on another player (Soulstone)
-------------------------------------------------------------------------------

local function OnCastSent(target, castGUID)
    target, castGUID = Plain(target), Plain(castGUID)
    if castGUID and target and target ~= "" then castTargets[castGUID] = target end
end

local function OnCastSucceeded(castGUID, spellID)
    castGUID, spellID = Plain(castGUID), Plain(spellID)
    local target = castGUID and castTargets[castGUID]
    if castGUID then castTargets[castGUID] = nil end
    if not target or not spellID then return end
    local spellName = SafeCall(ns.GetSpellName, spellID)
    local kind = ns.StoneKind(spellName)
    -- "Create Soulstone" also mentions the stone; only the stone's own use counts.
    if not kind or spellName:find("^Create") or not db.stones[kind] then return end
    if target == SafeCall(UnitName, "player") then return end
    Tell(target, string.format("The %s I just used on you holds %s.", kind, SoulText(db.stones[kind])))
    db.stones[kind] = nil
end

-------------------------------------------------------------------------------
-- Tooltips: show the soul on the stone itself
-------------------------------------------------------------------------------

local function HookTooltip()
    if not GameTooltip.SetBagItem then return end
    hooksecurefunc(GameTooltip, "SetBagItem", function(tooltip, bag, slot)
        if not db.tooltip then return end
        local link = SafeCall(ns.GetContainerItemLink, bag, slot)
        local kind = link and ns.StoneKind(link:match("%[(.-)%]"))
        local rec = kind and db.stones[kind]
        if not rec then return end
        tooltip:AddLine(ns.NumberTag(rec) .. "Holds the soul of " .. ns.ColoredName(rec), 1, 1, 1)
        tooltip:AddLine(ns.Location(rec), 0.85, 0.85, 0.85)
        tooltip:Show()
    end)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    if event == "TRADE_SHOW" then
        tradePartner, tradeStones = TradePartnerName(), nil
    elseif event == "TRADE_ACCEPT_UPDATE" then
        SnapshotTrade()
    elseif event == "UI_INFO_MESSAGE" then
        -- (messageType, message) on current clients; just the message on old ones.
        local msg = Plain(arg2) or Plain(arg1)
        if ERR_TRADE_COMPLETE and msg == ERR_TRADE_COMPLETE then OnTradeComplete() end
    elseif event == "UNIT_SPELLCAST_SENT" then
        if arg1 == "player" then OnCastSent(arg2, arg3) end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 == "player" then OnCastSucceeded(arg2, arg3) end
    elseif event == "BAG_UPDATE_DELAYED" then
        -- A finished trade empties our bags before "Trade complete" arrives,
        -- so let the trade snapshot speak for traded stones.
        C_Timer.After(1, CheckStonesInBags)
    end
end)

table.insert(ns.loginHandlers, function(savedDB)
    db = savedDB
    Plain, SafeCall = ns.Plain, ns.SafeCall
    for _, event in ipairs({ "TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "UI_INFO_MESSAGE", "BAG_UPDATE_DELAYED" }) do
        pcall(events.RegisterEvent, events, event)
    end
    for _, event in ipairs({ "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED" }) do
        if not (events.RegisterUnitEvent and pcall(events.RegisterUnitEvent, events, event, "player")) then
            pcall(events.RegisterEvent, events, event)
        end
    end
    HookTooltip()
end)
