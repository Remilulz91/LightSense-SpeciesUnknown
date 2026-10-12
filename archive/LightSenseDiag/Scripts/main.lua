-- LightSenseDiag v0.3.0 - Species: Unknown (UE4SS Lua)
-- Author: Remilulz_91
--
-- READ-ONLY diagnostic for the LightSense mod (monsters reacting to flashlights).
-- Nothing in the game is written: properties are only read, hooks only log.
--
-- Keys (Ctrl+):  F5 scan | F7 monitor ON/OFF | F8 hooks ON/OFF | F3 marker | F2 summary
--
-- v0.3: Poulpi focus - every simple Blueprint property of the classes listed in
--   watchAllForClasses is tracked (to see what changes when the Poulpi flees by itself),
--   very frequent BigRobot functions excluded from the hooks.
--
-- v0.2 (after the v0.1 test: 210 ms freeze every 5 s, crash in UE4SS.dll when leaving a mission):
--   - flashlight read directly on the pawn (FlashLightOn + "SpotLight" component),
--     no more scan of the ~4,800 LightComponents of the level;
--   - hooks on LightComponent/SceneComponent removed (16,818 SetIntensity calls in 10 min);
--   - Ctrl+F8 OFF really unregisters the hooks: turn them OFF before leaving a mission;
--   - monitor limited to a short list of properties (playerWatch / monsterWatch);
--   - CONE IN lines show the monster state (vision threshold, target...).
--
-- Lessons from AlliedDefense applied here:
--   - no NotifyOnNewObject / ExecuteWithDelay (async callbacks corrupted Lua state);
--   - UObjects are never kept across frames (re-found every tick);
--   - every hook is opt-in (Ctrl+F8) and only logs;
--   - loops at 500 ms minimum (a 100 ms loop crashed the game).

local VERSION = "0.3.0"
local MOD = "LightSenseDiag"

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local okCfg, cfg = pcall(require, "config")
if not okCfg or type(cfg) ~= "table" then cfg = {} end
local function default(k, v) if cfg[k] == nil then cfg[k] = v end end
default("playerBaseClass", "BP_ParentCharacter_C")
default("monsterBaseClasses", { "BP_ParentMonster_C", "BP_BaseMonster_C" })
default("modifier", "CONTROL")
default("keys", { summary = "F2", marker = "F3", scan = "F5", monitor = "F7", hooks = "F8" })
default("flashlightOnProp", "FlashLightOn")
default("flashlightComponent", "SpotLight")
default("flashlightProps", { "FlashLightOn", "FlashLightIntensity", "FlashLightPower", "FlashlightCooldown" })
default("defaultConeAngle", 45)
default("defaultRange", 2200)
default("scanPlayerClass", false)
default("monitorIntervalMs", 500)
default("watchAllBlueprintProps", false)
default("watchAllForClasses", {})
default("playerWatch", { "FlashLightOn", "FlashLightIntensity", "FlashlightCooldown" })
default("monsterWatch", { "CanSeeTarget", "InstantSee", "JustSeenA NewTarget", "IsEscaping",
                          "LastTargetActor", "LastMainTarget", "SeeThreshold", "HearSoundThreshold" })
default("monsterBriefProps", { "SeeThreshold", "CanSeeTarget", "InstantSee", "SeeDistance", "Vision Cone Angle" })
default("floatStep", 0.5)
default("monitorPropTypes", { "BoolProperty", "ByteProperty", "EnumProperty", "IntProperty",
                              "NameProperty", "ObjectProperty", "ClassProperty" })
default("monitorBlackboardVectors", false)
default("monitorIgnore", { "^ubergraphframe$", "^defaultsceneroot$" })
default("coneTest", true)
default("lineOfSightTest", false)
default("slowTickMs", 30)
default("highlightPatterns", { "light", "flash", "lamp", "see", "vision", "bt", "behavio", "state", "target" })
default("fullDumpClasses", { "AIPerceptionComponent", "AISenseConfig", "PawnSensingComponent" })
default("hookPatterns", { "see", "sight", "vision", "hear", "sound", "search", "escape", "target" })
default("playerHookPatterns", { "flash", "lamp", "torch" })
default("hookExclude", { "^executeubergraph", "^receivetick$", "^userconstructionscript$", "tick" })
default("maxHooks", 80)
default("logHookInstall", false)
default("hookDedupSeconds", 2.0)
default("nativeHooks", {})

---------------------------------------------------------------------------
-- Log (one timestamped file per game launch, in the mod folder)
---------------------------------------------------------------------------
local function modDir()
    local ok, info = pcall(debug.getinfo, modDir, "S")
    if ok and info and type(info.source) == "string" then
        local src = info.source:gsub("^@", "")
        local scripts = src:match("^(.*)[/\\][^/\\]+$")
        if scripts then return scripts:match("^(.*)[/\\][^/\\]+$") or scripts end
    end
    return "."
end

local LOG_PATH = modDir() .. "\\LightSenseDiag_" .. os.date("%Y%m%d_%H%M%S") .. ".log"
local logFile = io.open(LOG_PATH, "a")

local function log(fmt, ...)
    local msg
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, fmt, ...)
        msg = ok and s or (tostring(fmt) .. " <format err>")
    else
        msg = tostring(fmt)
    end
    pcall(print, "[" .. MOD .. "] " .. msg .. "\n")
    if logFile then
        pcall(function()
            logFile:write(tostring(os.date("%H:%M:%S")) .. " " .. msg .. "\n")
            logFile:flush()
        end)
    end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

local function valid(o)
    if o == nil or type(o) ~= "userdata" then return false end
    return safe(function() return o:IsValid() end) == true
end

local function fullName(o)  return safe(function() return o:GetFullName() end) or "?" end
local function shortName(o) return safe(function() return o:GetFName():ToString() end) or "?" end
local function classOf(o)   return safe(function() return o:GetClass() end) end
local function className(o) return shortName(classOf(o)) end
local function fieldClassName(p) return safe(function() return p:GetClass():GetFName():ToString() end) or "?" end
local function isDefaultObject(o) return string.find(shortName(o), "Default__", 1, true) ~= nil end
local function objPath(o) return (fullName(o):gsub("^%S+%s+", "")) end
local function addr(o) return safe(function() return o:GetAddress() end) end
local function readProp(o, name) return safe(function() return o[name] end) end
local function isBp(name) return type(name) == "string" and name:sub(-2) == "_C" end

local function same(a, b)
    if not valid(a) or not valid(b) then return false end
    local x, y = addr(a), addr(b)
    if x ~= nil and y ~= nil then return x == y end
    return fullName(a) == fullName(b)
end

local function matchAny(name, patterns)
    local n = string.lower(name or "")
    for _, p in ipairs(patterns or {}) do
        if safe(function() return n:find(p) end) then return true end
    end
    return false
end

local function inList(name, list)
    for _, n in ipairs(list or {}) do if n == name then return true end end
    return false
end

-- Class chain of an object: { {cls=UClass, name="BP_X_C"}, ... } from most derived to UObject
local function classChain(o)
    local out = {}
    local c = classOf(o)
    local guard = 0
    while valid(c) and guard < 40 do
        out[#out + 1] = { cls = c, name = shortName(c) }
        local cur = c
        c = safe(function() return cur:GetSuperStruct() end)
        guard = guard + 1
    end
    return out
end

local function chainNames(o)
    local n = {}
    for _, l in ipairs(classChain(o)) do n[#n + 1] = l.name end
    return n
end

local function chainHas(o, name) return inList(name, chainNames(o)) end

local function fmtNum(v)
    if math.type and math.type(v) == "integer" then return tostring(v) end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.2f", v)
end

local function fmtVec(v)
    local x = safe(function() return v.X end)
    if type(x) ~= "number" then return nil end
    return string.format("(%.0f, %.0f, %.0f)", x, safe(function() return v.Y end) or 0, safe(function() return v.Z end) or 0)
end

local function fmtRot(v)
    local p = safe(function() return v.Pitch end)
    if type(p) ~= "number" then return nil end
    return string.format("(P%.0f Y%.0f R%.0f)", p, safe(function() return v.Yaw end) or 0, safe(function() return v.Roll end) or 0)
end

local monsterSet  -- forward (classes of monster bases, for tags)

local function pawnTag(o)
    if valid(readProp(o, "PlayerState")) and chainHas(o, "Pawn") then return " [PLAYER]" end
    for _, b in ipairs(cfg.monsterBaseClasses) do
        if chainHas(o, b) then return " [MONSTER]" end
    end
    return ""
end

local function fmtValue(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "number" then return fmtNum(v) end
    if t == "table" then return fmtVec(v) or fmtRot(v) or tostring(v) end
    if t ~= "userdata" then return tostring(v) end
    local n = safe(function() return v:GetArrayNum() end)
    if type(n) == "number" then return "TArray[" .. n .. "]" end
    local isObj = safe(function() return v.IsValid ~= nil and v.GetFullName ~= nil end)
    if isObj then
        if not valid(v) then return "None" end
        return shortName(v) .. " <" .. className(v) .. ">" .. pawnTag(v)
    end
    local s = safe(function() return v:ToString() end)
    if type(s) == "string" then return '"' .. s .. '"' end
    return fmtVec(v) or fmtRot(v) or tostring(v)
end

local function findAll(cname)
    local out = {}
    for _, a in ipairs(safe(function() return FindAllOf(cname) end) or {}) do
        if valid(a) and not isDefaultObject(a) then out[#out + 1] = a end
    end
    return out
end

-- FindAllOf over several class names, without duplicates
local function findAllMulti(names)
    local out, seen = {}, {}
    for _, cn in ipairs(names) do
        for _, a in ipairs(findAll(cn)) do
            local k = addr(a) or fullName(a)
            if not seen[k] then seen[k] = true out[#out + 1] = a end
        end
    end
    return out
end

local function forEachArray(arr, fn)
    if arr == nil then return end
    safe(function()
        arr:ForEach(function(i, e)
            local v = safe(function() return e:get() end)
            if v == nil then v = e end
            local ok, err = pcall(fn, i, v)
            if not ok then log("  (array element error: %s)", tostring(err)) end
        end)
    end)
end

local function location(a)
    local v = safe(function() return a:K2_GetActorLocation() end)
    if v == nil then return nil end
    local x = safe(function() return v.X end)
    if type(x) ~= "number" then return nil end
    return x, safe(function() return v.Y end) or 0, safe(function() return v.Z end) or 0
end

local function compLocation(c)
    local v = safe(function() return c:K2_GetComponentLocation() end)
    if v == nil then return nil end
    local x = safe(function() return v.X end)
    if type(x) ~= "number" then return nil end
    return x, safe(function() return v.Y end) or 0, safe(function() return v.Z end) or 0
end

local function compForward(c)
    local v = safe(function() return c:GetForwardVector() end)
    if v == nil then return nil end
    local x = safe(function() return v.X end)
    if type(x) ~= "number" then return nil end
    return x, safe(function() return v.Y end) or 0, safe(function() return v.Z end) or 0
end

local function distance(ax, ay, az, bx, by, bz)
    local dx, dy, dz = bx - ax, by - ay, bz - az
    return math.sqrt(dx * dx + dy * dy + dz * dz), dx, dy, dz
end

local actorComponentClass
local function components(actor)
    if not valid(actorComponentClass) then
        actorComponentClass = safe(function() return StaticFindObject("/Script/Engine.ActorComponent") end)
    end
    local out = {}
    if not valid(actorComponentClass) then return out end
    local arr = safe(function() return actor:K2_GetComponentsByClass(actorComponentClass) end)
    forEachArray(arr, function(_, c) if valid(c) then out[#out + 1] = c end end)
    return out
end

---------------------------------------------------------------------------
-- Players / monsters / controllers
---------------------------------------------------------------------------
local function playerPawns()
    local out, seen = {}, {}
    local function add(p)
        if not valid(p) then return end
        local k = addr(p) or fullName(p)
        if seen[k] then return end
        seen[k] = true
        out[#out + 1] = p
    end
    for _, pc in ipairs(findAll("PlayerController")) do add(readProp(pc, "Pawn")) end
    for _, p in ipairs(findAll(cfg.playerBaseClass)) do add(p) end
    return out
end

local function monsters() return findAllMulti(cfg.monsterBaseClasses) end

local function controllerOf(pawn)
    local c = readProp(pawn, "Controller")
    if not valid(c) then c = safe(function() return pawn:GetController() end) end
    if valid(c) then return c end
    return nil
end

local function blackboardOf(ctrl)
    if not valid(ctrl) then return nil end
    local bb = readProp(ctrl, "Blackboard")
    if valid(bb) then return bb end
    for _, c in ipairs(components(ctrl)) do
        if className(c):find("Blackboard") then return c end
    end
    return nil
end

local function describeOwner(o)
    -- "Component@OwnerPawn" / "Controller@Pawn" / name
    if not valid(o) then return "?" end
    local cn = className(o)
    if cn:find("Component") then
        local ow = safe(function() return o:GetOwner() end)
        if valid(ow) then
            local pw = readProp(ow, "Pawn")
            return shortName(o) .. "@" .. (valid(pw) and shortName(pw) or shortName(ow))
        end
    elseif cn:find("Controller") then
        local pw = readProp(o, "Pawn")
        if valid(pw) then return shortName(o) .. "@" .. shortName(pw) end
    end
    return shortName(o)
end

---------------------------------------------------------------------------
-- Blackboard
---------------------------------------------------------------------------
local function blackboardKeys(data, out, depth)
    out = out or {}
    depth = depth or 0
    if not valid(data) or depth > 6 then return out end
    blackboardKeys(readProp(data, "Parent"), out, depth + 1)
    forEachArray(readProp(data, "Keys"), function(_, e)
        local n = safe(function() return e.EntryName:ToString() end) or "?"
        local kt = safe(function() return e.KeyType end)
        local t = valid(kt) and className(kt) or "?"
        t = (t:gsub("^BlackboardKeyType_", ""))
        local extra = ""
        if t:find("Enum") then extra = shortName(readProp(kt, "EnumType"))
        elseif t == "Object" or t == "Class" then extra = shortName(readProp(kt, "BaseClass")) end
        out[#out + 1] = { name = n, type = t, extra = extra, from = shortName(data) }
    end)
    return out
end

local BB_GETTERS = {
    Bool = "GetValueAsBool", Object = "GetValueAsObject", Vector = "GetValueAsVector",
    Float = "GetValueAsFloat", Int = "GetValueAsInt", Enum = "GetValueAsEnum",
    NativeEnum = "GetValueAsEnum", Name = "GetValueAsName", String = "GetValueAsString",
    Class = "GetValueAsClass", Rotator = "GetValueAsRotator",
}

local function blackboardValue(bb, key)
    local g = BB_GETTERS[key.type]
    if not g then return "<" .. key.type .. ">" end
    local v = safe(function() return bb[g](bb, FName(key.name)) end)
    return fmtValue(v)
end

---------------------------------------------------------------------------
-- Class dump
---------------------------------------------------------------------------
local dumped = {}   -- class full name -> true (reset on every scan)

local function propList(cls)
    local out = {}
    safe(function()
        cls:ForEachProperty(function(p)
            out[#out + 1] = { name = shortName(p), type = fieldClassName(p) }
        end)
    end)
    return out
end

local function funcParams(f)
    local params = {}
    safe(function()
        f:ForEachProperty(function(p)
            params[#params + 1] = { name = shortName(p), type = fieldClassName(p) }
        end)
    end)
    return params
end

local function isLocalVar(name)
    return name:find("^CallFunc_") or name:find("^K2Node_") or name:find("^Temp_") or name:find("^LocalVar")
end

local function dumpClassLevel(cls, obj, levelName)
    log("    [%s] %s", levelName, fullName(cls))
    for _, p in ipairs(propList(cls)) do
        local mark = matchAny(p.name, cfg.highlightPatterns) and "**" or "  "
        log("    %s prop  %-36s %-20s = %s", mark, p.name, p.type, fmtValue(readProp(obj, p.name)))
    end
    local funcs = {}
    safe(function() cls:ForEachFunction(function(f) funcs[#funcs + 1] = f end) end)
    for _, f in ipairs(funcs) do
        local ps = {}
        for _, p in ipairs(funcParams(f)) do
            if not isLocalVar(p.name) then ps[#ps + 1] = p.name .. ":" .. p.type end
        end
        local fname = shortName(f)
        local mark = matchAny(fname, cfg.highlightPatterns) and "**" or "  "
        log("    %s func  %s(%s)", mark, fname, table.concat(ps, ", "))
    end
end

-- Values only (class already dumped): highlighted properties of this instance
local function dumpLevelValues(cls, obj, levelName)
    local parts = {}
    for _, p in ipairs(propList(cls)) do
        if matchAny(p.name, cfg.highlightPatterns) then
            parts[#parts + 1] = p.name .. "=" .. fmtValue(readProp(obj, p.name))
        end
    end
    log("    [%s] (dumped above) values: %s", levelName, #parts > 0 and table.concat(parts, " | ") or "-")
end

local STOP = { Actor = true, Pawn = true, Character = true, Controller = true, AIController = true,
               PlayerController = true, ActorComponent = true, SceneComponent = true, Object = true }

-- full = dump engine levels too (until a STOP class); otherwise Blueprint levels only
local function dumpObject(obj, label, full)
    if not valid(obj) then log("  %s: None", label) return end
    local chain = classChain(obj)
    local names = {}
    for _, l in ipairs(chain) do names[#names + 1] = l.name end
    log("  %s %s : %s", label, shortName(obj), table.concat(names, " > "))
    for _, l in ipairs(chain) do
        if STOP[l.name] then break end
        if isBp(l.name) or full then
            local key = fullName(l.cls)
            if dumped[key] then
                dumpLevelValues(l.cls, obj, l.name)
            else
                dumped[key] = true
                dumpClassLevel(l.cls, obj, l.name)
            end
        end
    end
end

local function wantsFullDump(obj)
    for _, cn in ipairs(cfg.fullDumpClasses) do
        if chainHas(obj, cn) then return true end
    end
    return false
end

local function listComponents(actor, indent)
    indent = indent or "    "
    local comps = components(actor)
    log("%scomponents: %d", indent, #comps)
    for _, c in ipairs(comps) do
        local parent = safe(function() return c:GetAttachParent() end)
        log("%s  - %-40s <%s>%s", indent, shortName(c), className(c),
            valid(parent) and ("  attached to " .. shortName(parent)) or "")
    end
    return comps
end

---------------------------------------------------------------------------
-- Flashlight (v0.2: read directly on the player pawn)
-- v0.1 searched the ~4,800 LightComponents of the level every 5 s: 210 ms freeze.
-- v0.1 found it: BP_Character_C.FlashLightOn (bool) + component "SpotLight"
-- (attached to SceneFlashlight, outer cone 45, range 2200).
---------------------------------------------------------------------------
local function flashlightOf(p)
    local c = readProp(p, cfg.flashlightComponent)
    if valid(c) then return c end
    return nil
end

local function flashlightOn(p)
    local on = readProp(p, cfg.flashlightOnProp)
    if type(on) == "boolean" then return on end
    return nil
end

local function flashlightState(p)
    local parts = {}
    for _, n in ipairs(cfg.flashlightProps) do parts[#parts + 1] = n .. "=" .. fmtValue(readProp(p, n)) end
    local c = flashlightOf(p)
    if c then
        parts[#parts + 1] = string.format("beam %s: visible=%s intensity=%s outerCone=%s range=%s",
            shortName(c), fmtValue(safe(function() return c:IsVisible() end)), fmtValue(readProp(c, "Intensity")),
            fmtValue(readProp(c, "OuterConeAngle")), fmtValue(readProp(c, "AttenuationRadius")))
    else
        parts[#parts + 1] = "beam component '" .. tostring(cfg.flashlightComponent) .. "' NOT found"
    end
    return table.concat(parts, " | ")
end

-- Is monster m inside the beam c? -> inCone, distance, angle, outer, range (nil if unknown)
local function coneTest(c, m)
    local lx, ly, lz = compLocation(c)
    local fx, fy, fz = compForward(c)
    local mx, my, mz = location(m)
    if not (lx and fx and mx) then return nil end
    local d, dx, dy, dz = distance(lx, ly, lz, mx, my, mz)
    local cosA = d > 1 and (dx * fx + dy * fy + dz * fz) / d or 1
    if cosA > 1 then cosA = 1 elseif cosA < -1 then cosA = -1 end
    local angle = math.deg(math.acos(cosA))
    local outer = readProp(c, "OuterConeAngle")
    if type(outer) ~= "number" then outer = cfg.defaultConeAngle end
    local range = readProp(c, "AttenuationRadius")
    if type(range) ~= "number" then range = cfg.defaultRange end
    return angle <= outer and d <= range, d, angle, outer, range
end

---------------------------------------------------------------------------
-- SCAN (Ctrl+F5)
---------------------------------------------------------------------------
local scanN = 0
local monsterClassesSeen, monsterClassOrder = {}, {}

local function scan()
    scanN = scanN + 1
    dumped = {}
    local t0 = os.clock()
    log("==================== SCAN %d (v%s) ====================", scanN, VERSION)

    -- 1. Players --------------------------------------------------------
    local pcs = findAll("PlayerController")
    log("-- 1. PLAYERS  (PlayerControllers: %d)", #pcs)
    for _, pc in ipairs(pcs) do
        log("  %s  local=%s  authority=%s  pawn=%s", shortName(pc),
            fmtValue(safe(function() return pc:IsLocalController() end)),
            fmtValue(safe(function() return pc:HasAuthority() end)),
            fmtValue(readProp(pc, "Pawn")))
    end
    local players = playerPawns()
    log("  player pawns: %d", #players)
    for i, p in ipairs(players) do
        log("  ---- player %d: %s  pos=%s  authority=%s  locallyControlled=%s", i, shortName(p),
            fmtValue(safe(function() return p:K2_GetActorLocation() end)),
            fmtValue(safe(function() return p:HasAuthority() end)),
            fmtValue(safe(function() return p:IsLocallyControlled() end)))
        if cfg.scanPlayerClass and i == 1 then
            dumpObject(p, "pawn", false)
            listComponents(p)
        end
    end

    -- 2. Flashlights ----------------------------------------------------
    log("-- 2. FLASHLIGHTS")
    for _, p in ipairs(players) do
        log("  %s : %s", shortName(p), flashlightState(p))
        local c = flashlightOf(p)
        if c then
            local fx, fy, fz = compForward(c)
            log("      beam location=%s forward=(%.2f, %.2f, %.2f) attachParent=%s",
                fmtValue(safe(function() return c:K2_GetComponentLocation() end)), fx or 0, fy or 0, fz or 0,
                fmtValue(safe(function() return c:GetAttachParent() end)))
        end
    end

    -- 3. Monsters -------------------------------------------------------
    local mons = monsters()
    local byClass, order = {}, {}
    for _, m in ipairs(mons) do
        local cn = className(m)
        if not byClass[cn] then byClass[cn] = { n = 0, dead = 0, first = m } order[#order + 1] = cn end
        byClass[cn].n = byClass[cn].n + 1
        if readProp(m, "IsDead") == true then byClass[cn].dead = byClass[cn].dead + 1 end
        if not monsterClassesSeen[cn] then monsterClassesSeen[cn] = true monsterClassOrder[#monsterClassOrder + 1] = cn end
    end
    log("-- 3. MONSTERS: %d  (classes: %d)", #mons, #order)
    for _, cn in ipairs(order) do
        log("  %-34s x%-3d dead=%d  | %s", cn, byClass[cn].n, byClass[cn].dead, table.concat(chainNames(byClass[cn].first), " > "))
    end
    for _, cn in ipairs(order) do
        local m = byClass[cn].first
        log("  ---- monster class %s  (instance %s, pos=%s, authority=%s)", cn, shortName(m),
            fmtValue(safe(function() return m:K2_GetActorLocation() end)),
            fmtValue(safe(function() return m:HasAuthority() end)))
        dumpObject(m, "pawn", false)
        local comps = listComponents(m)
        for _, c in ipairs(comps) do
            if wantsFullDump(c) or isBp(className(c)) then dumpObject(c, "  component", wantsFullDump(c)) end
        end
        local ctrl = controllerOf(m)
        if not ctrl then
            log("    controller: None")
        else
            dumpObject(ctrl, "  controller", false)
            local ccomps = listComponents(ctrl, "      ")
            for _, c in ipairs(ccomps) do
                if wantsFullDump(c) or isBp(className(c)) then dumpObject(c, "    ctrl component", wantsFullDump(c)) end
            end
            log("    BrainComponent: %s", fmtValue(readProp(ctrl, "BrainComponent")))
            local perc = readProp(ctrl, "PerceptionComponent")
            log("    PerceptionComponent: %s", fmtValue(perc))
            if valid(perc) then
                log("      DominantSense: %s", fmtValue(readProp(perc, "DominantSense")))
                forEachArray(readProp(perc, "SensesConfig"), function(i, sc)
                    log("      sense config %d: %s", i, fmtValue(sc))
                    if valid(sc) then dumpObject(sc, "      sense", true) end
                end)
            end
            local bb = blackboardOf(ctrl)
            log("    Blackboard: %s", fmtValue(bb))
            if valid(bb) then
                local data = readProp(bb, "BlackboardAsset")
                log("      BlackboardAsset: %s", fmtValue(data))
                for _, k in ipairs(blackboardKeys(data)) do
                    log("      key %-30s %-10s %-22s = %s   (from %s)", k.name, k.type, k.extra, blackboardValue(bb, k), k.from)
                end
            end
        end
    end
    if #mons == 0 then log("  none: start a contract and scan again once specimens are spawned") end
    log("  monster classes seen since launch: %s", #monsterClassOrder > 0 and table.concat(monsterClassOrder, ", ") or "-")

    -- 4. AI assets and senses --------------------------------------------
    log("-- 4. AI ASSETS")
    local bts = findAll("BehaviorTree")
    log("  BehaviorTree assets loaded: %d", #bts)
    for _, bt in ipairs(bts) do
        log("    %-40s blackboard=%s", objPath(bt), fmtValue(readProp(bt, "BlackboardAsset")))
    end
    local bbs = findAll("BlackboardData")
    log("  BlackboardData assets loaded: %d", #bbs)
    for _, d in ipairs(bbs) do
        local ks = {}
        for _, k in ipairs(blackboardKeys(d)) do ks[#ks + 1] = k.name .. ":" .. k.type end
        log("    %-40s keys: %s", objPath(d), table.concat(ks, ", "))
    end
    local senses = findAll("AISense")
    log("  AISense instances: %d", #senses)
    for _, s in ipairs(senses) do log("    %s <%s>", shortName(s), className(s)) end
    log("  AIControllers in the world: %d", #findAll("AIController"))

    log("==================== END SCAN %d (%.0f ms) ====================", scanN, (os.clock() - t0) * 1000)
end

---------------------------------------------------------------------------
-- MONITOR (Ctrl+F7): changes only
---------------------------------------------------------------------------
local monitor = { on = false, gen = 0, busy = false, last = {}, watch = {}, ticks = 0 }

-- All simple Blueprint properties of a class (only when watchAllBlueprintProps = true)
local function watchAllList(obj)
    local cn = className(obj)
    if monitor.watch[cn] then return monitor.watch[cn] end
    local list, types = {}, {}
    for _, t in ipairs(cfg.monitorPropTypes) do types[t] = true end
    for _, l in ipairs(classChain(obj)) do
        if STOP[l.name] then break end
        if isBp(l.name) then
            for _, p in ipairs(propList(l.cls)) do
                if types[p.type] and not matchAny(p.name, cfg.monitorIgnore) then list[#list + 1] = p.name end
            end
        end
    end
    monitor.watch[cn] = list
    log("MONITOR watches %d properties on %s", #list, cn)
    return list
end

-- Floats are rounded (cfg.floatStep) so that slow timers do not flood the log
local function watchedValue(obj, prop)
    local v = readProp(obj, prop)
    if v == nil then return nil end
    if type(v) == "number" and not (math.type and math.type(v) == "integer") then
        local step = cfg.floatStep
        v = math.floor(v / step + 0.5) * step
    end
    return fmtValue(v)
end

local function changed(key, value, label)
    if value == nil then return end
    local old = monitor.last[key]
    monitor.last[key] = value
    if old ~= nil and old ~= value then
        log("%-8s %s : %s  ->  %s", label, key, old, value)
    end
end

-- Short state of a monster, logged when it enters a beam
local function monsterBrief(m, bb)
    local parts = {}
    for _, n in ipairs(cfg.monsterBriefProps) do
        local v = watchedValue(m, n)
        if v ~= nil then parts[#parts + 1] = n .. "=" .. v end
    end
    if valid(bb) then
        local v = safe(function() return bb:GetValueAsObject(FName("TargetActor")) end)
        parts[#parts + 1] = "BB.TargetActor=" .. (valid(v) and shortName(v) or "None")
    end
    return table.concat(parts, " ")
end

local function monitorTick()
    local t0 = os.clock()
    monitor.ticks = monitor.ticks + 1
    local players = playerPawns()

    -- players + their flashlight
    local beams = {}
    for _, p in ipairs(players) do
        local pn = shortName(p)
        local list = cfg.watchAllBlueprintProps and watchAllList(p) or cfg.playerWatch
        for _, prop in ipairs(list) do changed(pn .. "." .. prop, watchedValue(p, prop), "PLAYER") end
        local c = flashlightOf(p)
        if c then
            changed(pn .. ".beam", string.format("visible=%s intensity=%s",
                fmtValue(safe(function() return c:IsVisible() end)), watchedValue(c, "Intensity")), "LIGHT")
            beams[#beams + 1] = { comp = c, pawn = p, name = pn, on = flashlightOn(p) == true }
        end
    end

    -- monsters, blackboards, cone test
    for _, m in ipairs(monsters()) do
        local mn = shortName(m)
        local list = (cfg.watchAllBlueprintProps or inList(className(m), cfg.watchAllForClasses)) and watchAllList(m) or cfg.monsterWatch
        for _, prop in ipairs(list) do changed(mn .. "." .. prop, watchedValue(m, prop), "MONSTER") end
        local ctrl = controllerOf(m)
        local bb = blackboardOf(ctrl)
        if valid(bb) then
            for _, k in ipairs(blackboardKeys(readProp(bb, "BlackboardAsset"))) do
                if k.type ~= "Float" and k.type ~= "Rotator" and (k.type ~= "Vector" or cfg.monitorBlackboardVectors) then
                    changed(mn .. ".BB." .. k.name, blackboardValue(bb, k), "BB")
                end
            end
        end
        if cfg.coneTest and readProp(m, "IsDead") ~= true then
            for _, b in ipairs(beams) do
                local inCone, d, angle, outer, range = false, nil, nil, nil, nil
                if b.on then inCone, d, angle, outer, range = coneTest(b.comp, m) end
                inCone = inCone == true
                local key = mn .. "<-" .. b.name
                local prev = monitor.last[key]
                monitor.last[key] = inCone
                if prev ~= nil and prev ~= inCone then
                    if inCone then
                        local los = ""
                        if cfg.lineOfSightTest and ctrl then
                            los = "  LineOfSightTo=" .. fmtValue(safe(function()
                                return ctrl:LineOfSightTo(b.pawn, { X = 0, Y = 0, Z = 0 }, false) end))
                        end
                        log("CONE     IN  %s  (d=%.0f angle=%.1f outer=%.1f range=%.0f)%s  | %s",
                            key, d, angle, outer, range, los, monsterBrief(m, bb))
                    else
                        log("CONE     OUT %s%s", key, b.on and "" or "  (lamp off)")
                    end
                end
            end
        end
    end

    local dt = (os.clock() - t0) * 1000
    if dt > cfg.slowTickMs then log("SLOW monitor tick: %.0f ms", dt) end
end

local function toggleMonitor()
    monitor.on = not monitor.on
    monitor.gen = monitor.gen + 1
    if not monitor.on then log("MONITOR: OFF (%d ticks)", monitor.ticks) return end
    monitor.last, monitor.watch = {}, {}
    log("MONITOR: ON (%d ms) - first values are not logged, only changes", cfg.monitorIntervalMs)
    local myGen = monitor.gen
    LoopAsync(cfg.monitorIntervalMs, function()
        if not monitor.on or monitor.gen ~= myGen then return true end
        if not monitor.busy then
            monitor.busy = true
            ExecuteInGameThread(function()
                local ok, err = pcall(monitorTick)
                if not ok then log("MONITOR error: %s", tostring(err)) end
                monitor.busy = false
            end)
        end
        return false
    end)
end

---------------------------------------------------------------------------
-- HOOKS (Ctrl+F8): log only
-- v0.2: OFF really unregisters every hook (v0.1 crashed inside UE4SS.dll while
-- leaving a mission with 120 hooks installed). Turn hooks OFF before leaving.
---------------------------------------------------------------------------
local hooks = { on = false, list = {}, paths = {}, counts = {}, lastLine = {} }
local SIMPLE = { BoolProperty = true, ByteProperty = true, EnumProperty = true, IntProperty = true,
                 Int64Property = true, FloatProperty = true, DoubleProperty = true, NameProperty = true,
                 StrProperty = true, ObjectProperty = true, ClassProperty = true }

local function fmtArgs(spec, args)
    local out = {}
    for i = 1, #args do
        local p = spec.params[i]
        local name = p and p.name or ("arg" .. i)
        if p and SIMPLE[p.type] then
            out[#out + 1] = name .. "=" .. fmtValue(safe(function() return args[i]:get() end))
        else
            out[#out + 1] = name .. "=<" .. (p and p.type or "?") .. ">"
        end
    end
    return table.concat(out, ", ")
end

local function onCall(spec, ctx, args)
    hooks.counts[spec.label] = (hooks.counts[spec.label] or 0) + 1
    if not hooks.on or spec.quiet then return end
    local self = safe(function() return ctx:get() end)
    local who = describeOwner(self)
    local line = spec.label .. "(" .. fmtArgs(spec, args) .. ")"
    local key = who .. "|" .. spec.label
    local now = os.clock()
    local prev = hooks.lastLine[key]
    if prev and prev.line == line and (now - prev.t) < cfg.hookDedupSeconds then return end
    hooks.lastLine[key] = { line = line, t = now }
    log("CALL     %-34s %s", who, line)
end

local function hookFunction(path, label, params, opts)
    if hooks.paths[path] then return end
    if #hooks.list >= cfg.maxHooks then return end
    hooks.paths[path] = true
    local spec = { label = label, params = params, quiet = opts and opts.quiet }
    local ok, pre, post = pcall(RegisterHook, path, function(ctx, ...)
        local args = { ... }
        local ok2, e2 = pcall(onCall, spec, ctx, args)
        if not ok2 then log("HOOK error %s: %s", label, tostring(e2)) end
    end)
    if ok then
        hooks.list[#hooks.list + 1] = { path = path, pre = pre, post = post }
        if cfg.logHookInstall then log("HOOK +  %s%s", path, spec.quiet and "  (counted only)" or "") end
    else
        log("HOOK x  %s : %s", path, tostring(pre))
    end
end

local function paramsOf(f)
    local ps = {}
    for _, p in ipairs(funcParams(f)) do
        if isLocalVar(p.name) then break end
        ps[#ps + 1] = p
    end
    return ps
end

local function hookBlueprintFunctions(obj, patterns)
    for _, l in ipairs(classChain(obj)) do
        if STOP[l.name] then break end
        if isBp(l.name) then
            local clsPath = objPath(l.cls)
            local funcs = {}
            safe(function() l.cls:ForEachFunction(function(f) funcs[#funcs + 1] = f end) end)
            for _, f in ipairs(funcs) do
                local fname = shortName(f)
                if matchAny(fname, patterns) and not matchAny(fname, cfg.hookExclude) then
                    hookFunction(clsPath .. ":" .. fname, l.name .. ":" .. fname, paramsOf(f))
                end
            end
        end
    end
end

local function registerHooks()
    for _, h in ipairs(cfg.nativeHooks) do
        local f = safe(function() return StaticFindObject(h.path) end)
        hookFunction(h.path, (h.path:match("([^%.]+)$") or h.path), valid(f) and paramsOf(f) or {}, h)
    end
    local seen = {}
    -- players first (flashlight functions), then monsters and their controllers
    for _, p in ipairs(playerPawns()) do
        local cn = className(p)
        if not seen[cn] then seen[cn] = true hookBlueprintFunctions(p, cfg.playerHookPatterns) end
    end
    for _, m in ipairs(monsters()) do
        local cn = className(m)
        if not seen[cn] then
            seen[cn] = true
            hookBlueprintFunctions(m, cfg.hookPatterns)
            local ctrl = controllerOf(m)
            if ctrl then hookBlueprintFunctions(ctrl, cfg.hookPatterns) end
        end
    end
    log("HOOKS installed: %d (max %d)", #hooks.list, cfg.maxHooks)
end

local function unregisterHooks()
    local n = 0
    for _, h in ipairs(hooks.list) do
        local ok = pcall(UnregisterHook, h.path, h.pre, h.post)
        if ok then n = n + 1 else log("UNHOOK x  %s", h.path) end
    end
    log("HOOKS removed: %d / %d", n, #hooks.list)
    hooks.list, hooks.paths = {}, {}
end

local function toggleHooks()
    hooks.on = not hooks.on
    hooks.lastLine = {}
    if hooks.on then
        registerHooks()
        log("HOOKS: ON - turn them OFF (Ctrl+%s) before leaving the mission", cfg.keys.hooks)
    else
        unregisterHooks()
        log("HOOKS: OFF")
    end
end

local function summary()
    local rows = {}
    for name, n in pairs(hooks.counts) do rows[#rows + 1] = { name = name, n = n } end
    table.sort(rows, function(x, y) return x.n > y.n end)
    log("-------- CALL SUMMARY (%d functions) --------", #rows)
    for _, r in ipairs(rows) do log("  %10d  %s", r.n, r.name) end
    log("  monster classes seen: %s", #monsterClassOrder > 0 and table.concat(monsterClassOrder, ", ") or "-")
    log("---------------------------------------------")
end

local markerN = 0
local function marker()
    markerN = markerN + 1
    log("######## MARKER %d ########", markerN)
end

---------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------
local function bind(keyName, fn, label)
    local k = Key and Key[keyName]
    if not k then log("Unknown key '%s' for %s", tostring(keyName), label) return end
    local cb = function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log("ERROR %s: %s", label, tostring(err)) end
        end)
    end
    local mod = cfg.modifier and ModifierKey and ModifierKey[cfg.modifier]
    local ok, err
    if mod then ok, err = pcall(RegisterKeyBind, k, { mod }, cb)
    else ok, err = pcall(RegisterKeyBind, k, cb) end
    if not ok then log("Could not bind %s: %s", label, tostring(err)) end
end

local prefix = cfg.modifier and (cfg.modifier .. "+") or ""
log("%s v%s loaded (READ-ONLY). Log: %s", MOD, VERSION, LOG_PATH)
log("Keys: %s%s scan | %s%s monitor | %s%s hooks | %s%s marker | %s%s summary",
    prefix, cfg.keys.scan, prefix, cfg.keys.monitor, prefix, cfg.keys.hooks,
    prefix, cfg.keys.marker, prefix, cfg.keys.summary)

bind(cfg.keys.scan, scan, "scan")
bind(cfg.keys.monitor, toggleMonitor, "monitor")
bind(cfg.keys.hooks, toggleHooks, "hooks")
bind(cfg.keys.marker, marker, "marker")
bind(cfg.keys.summary, summary, "summary")
