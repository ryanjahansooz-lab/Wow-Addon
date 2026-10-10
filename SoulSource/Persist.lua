-- Beta workaround: the WoW: Forever beta client writes SavedVariables on exit
-- but never loads them, so every launch starts from scratch. Macros do survive
-- a restart, so on Forever we keep the lifetime shard count and the settings in
-- a small character macro named "SoulSource". Its lines start with "#", so
-- clicking it does nothing. On clients where saved variables work this file
-- does nothing.

local ADDON_NAME, ns = ...

local MACRO_NAME = "SoulSource"
local MACRO_ICON = 134400 -- question mark
local HEADER = "#SoulSource data - keep this macro to keep your shard count\n#ss "

local db
local hadSavedVariables
local ready = false      -- true once we've read the macro (or know there isn't one)
local writePending = false
local warned = false
local lastWritten

local function IsForeverClient()
    local iface = GetBuildInfo and select(4, GetBuildInfo())
    return type(iface) == "number" and iface >= 16000 and iface < 20000
end

local function MacroAPI()
    return CreateMacro and EditMacro and GetMacroBody and GetMacroIndexByName and true or false
end

local function Encode()
    local function flag(v) return v and "1" or "0" end
    return string.format("n=%d;st=%d;a=%s;s=%s;m=%s;t=%s;w=%s;mm=%d,%s",
        db.shardCount, db.stats.total, flag(db.announce), flag(db.say), flag(db.milestones),
        flag(db.tooltip), flag(db.stoneWhisper), math.floor((db.minimap.angle or 200) + 0.5),
        flag(db.minimap.hide))
end

local function Apply(data)
    local t = {}
    for k, v in data:gmatch("([%a]+)=([^;%s]*)") do t[k] = v end
    local n, st = tonumber(t.n), tonumber(t.st)
    if not n then return false end
    -- The count only ever goes up, whichever copy is newer.
    db.shardCount = math.max(db.shardCount, n)
    db.stats.total = math.max(db.stats.total, st or 0)
    if not hadSavedVariables then
        db.announce = t.a ~= "0"
        db.say = t.s ~= "0"
        db.milestones = t.m ~= "0"
        db.tooltip = t.t ~= "0"
        db.stoneWhisper = t.w ~= "0"
        local angle, hide = (t.mm or ""):match("^(-?%d+),(%d)$")
        if angle then
            db.minimap.angle = tonumber(angle)
            db.minimap.hide = hide == "1"
        end
    end
    return true
end

local function MacroIndex()
    local ok, index = pcall(GetMacroIndexByName, MACRO_NAME)
    return ok and index or 0
end

-- Returns true when the macro was found and applied.
local function Restore()
    if ready or not MacroAPI() then return false end
    local index = MacroIndex()
    if index == 0 then return false end
    local ok, body = pcall(GetMacroBody, index)
    local data = ok and body and body:match("#ss ([^\n]*)")
    if data and Apply(data) then
        ready = true
        lastWritten = Encode()
        ns.RefreshOptions()
        ns.UpdateMinimapButton()
        return true
    end
    return false
end

local function Write()
    writePending = false
    if not ready or not MacroAPI() then return end
    if InCombatLockdown() then
        writePending = true -- picked up by ns.OnCombatEnded
        return
    end
    local data = Encode()
    if data == lastWritten then return end
    local body = HEADER .. data
    local index = MacroIndex()
    local ok, result
    if index > 0 then
        ok, result = pcall(EditMacro, index, nil, nil, body)
    else
        ok, result = pcall(CreateMacro, MACRO_NAME, MACRO_ICON, body, true)
    end
    if ok and result then
        lastWritten = data
    elseif not warned then
        warned = true
        ns.Print("couldn't save your shard count in a macro (are your character macro slots full?). " ..
            "The beta forgets addon data on restart, so the count will start over next time.")
    end
end

local function Enabled()
    return db and IsForeverClient() and MacroAPI()
end

function ns.Persist()
    if not Enabled() or writePending then return end
    writePending = true
    C_Timer.After(1, Write)
end

function ns.OnCombatEnded()
    if Enabled() and writePending then Write() end
end

-- Called once the macro list has had time to load: from here on a missing
-- macro really is missing, so we may create it.
local function MarkReady()
    if ready then return end
    Restore()
    if ready then return end
    ready = true
    ns.Persist()
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event)
    if event == "UPDATE_MACROS" then
        if not Restore() and not ready then C_Timer.After(2, MarkReady) end
    elseif event == "PLAYER_LOGOUT" then
        -- Last chance; harmless if the client ignores it.
        if Enabled() and not InCombatLockdown() then Write() end
    end
end)

table.insert(ns.loginHandlers, function(savedDB)
    db = savedDB
    hadSavedVariables = ns.hadSavedVariables
    if not Enabled() then return end
    pcall(events.RegisterEvent, events, "UPDATE_MACROS")
    pcall(events.RegisterEvent, events, "PLAYER_LOGOUT")
    -- The macro list usually arrives a little after login.
    if not Restore() then C_Timer.After(10, MarkReady) end
end)

function ns.MacroBackupActive()
    return Enabled() and true or false
end
