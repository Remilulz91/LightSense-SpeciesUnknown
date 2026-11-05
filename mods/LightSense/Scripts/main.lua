-- LightSense v1.0.2 - Species: Unknown (UE4SS Lua)
-- Author: Remilulz_91
--
-- Monsters react to the players' flashlights.
--
-- How it works (everything found with LightSenseDiag):
--   - a player's lamp is on when BP_Character_C.FlashLightOn is true; the beam is its
--     "SpotLight" component (cone 45 deg, range 2200). FlashLight (Server) sends the state
--     to the host, so the host sees every player's lamp.
--   - every 0.5 s (host only), each living monster inside a lit beam (angle + range, and
--     not behind a wall) accumulates "lit time"; after litSeconds it reacts (then cooldown).
--   - reactions reuse the game's own mechanics (config "reactions", per monster class):
--       noise  : AISense_Hearing.ReportNoiseEvent at the player (the game does the same for
--                gunshots and footsteps) -> the monster investigates the light source
--       report : BigRobot.BPI_BigRobot_ReportTarget(player) (what its drones do) -> hunt
--       spot   : BPI_BasicMonster_SetMainTarget(player) -> the player becomes its target
--       flee   : target + BPI_Monster_SwitchBehavior(2) -> the game's own escape (BehaviorTree_Escape)
--       attack : target + BPI_Monster_SwitchBehavior(3) -> the game's own combat (BehaviorTree_Combat)
--   (v0.2: when a monster sees a player the game draws a behaviour at random -
--    PROBA_SeePlayer -> SwitchBehavior: 0 patrol, 1 search, 2 escape, 3 combat, 4 vent,
--    5 follow, 9 go far. "spot" let the Poulpi draw, so it did not always flee.)
--
-- Lessons from AlliedDefense: UObjects are never kept across ticks, loop >= 500 ms,
-- no hooks at all (only reads + a few calls on the game thread).

local VERSION = "1.0.2"
local MOD = "LightSense"

---------------------------------------------------------------------------
-- Configuration
---------------------------------------------------------------------------
local okCfg, cfg = pcall(require, "config")
if not okCfg or type(cfg) ~= "table" then cfg = {} end
local function default(k, v) if cfg[k] == nil then cfg[k] = v end end
default("enabled", true)
default("reactions", { default = { "noise" } })
default("litSeconds", 1.0)
default("litGraceSeconds", 1.5)
default("cooldownSeconds", 8)
default("lineOfSight", true)
default("coneScale", 1.0)
default("rangeScale", 1.0)
default("noiseLoudness", 1.0)
default("noiseExtraRange", 300)
default("noiseTag", "LightSense")
default("playerBaseClass", "BP_ParentCharacter_C")
default("monsterBaseClass", "BP_ParentMonster_C")
default("flashlightOnProp", "FlashLightOn")
default("flashlightComponent", "SpotLight")
default("defaultConeAngle", 45)
default("defaultRange", 2200)
default("tickMs", 500)
default("modifier", "ALT")
default("toggleKey", "F10")
default("verboseKey", "F11")
default("verbose", false)
default("behaviorIds", { escape = 2, combat = 3 })
default("closeRange", 500)
default("closeConeAngle", 80)
default("closeIgnoreWalls", true)
default("nearDebugRange", 500)
default("overrideRetries", 1)
default("remoteLampFromBeam", true)
default("remoteMinIntensity", 1)
default("lampIntensityProp", "FlashLightIntensity")
if cfg.tickMs < 500 then cfg.tickMs = 500 end

---------------------------------------------------------------------------
-- Log (LightSense.log in the mod folder, overwritten at every launch)
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

local LOG_PATH = modDir() .. "\\LightSense.log"
local logFile = io.open(LOG_PATH, "w")

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

local errCount = 0
local function logErr(where, err)
    errCount = errCount + 1
    if errCount <= 30 then log("ERROR %s: %s", where, tostring(err)) end
    if errCount == 30 then log("(further errors hidden)") end
end

local onceSeen = {}
local function logOnce(key, fmt, ...)
    if onceSeen[key] then return end
    onceSeen[key] = true
    log(fmt, ...)
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

local function shortName(o) return safe(function() return o:GetFName():ToString() end) or "?" end
local function className(o) return shortName(safe(function() return o:GetClass() end)) end
local function isDefaultObject(o) return string.find(shortName(o), "Default__", 1, true) ~= nil end
local function readProp(o, name) return safe(function() return o[name] end) end
local function fullPath(o) return ((safe(function() return o:GetFullName() end) or "?"):gsub("^%S+%s+", "")) end

local function findAll(cname)
    local out = {}
    for _, a in ipairs(safe(function() return FindAllOf(cname) end) or {}) do
        if valid(a) and not isDefaultObject(a) then out[#out + 1] = a end
    end
    return out
end

local function vec(v)
    if v == nil then return nil end
    local x = safe(function() return v.X end)
    if type(x) ~= "number" then return nil end
    return x, safe(function() return v.Y end) or 0, safe(function() return v.Z end) or 0
end

local function actorLoc(a) return vec(safe(function() return a:K2_GetActorLocation() end)) end
local function compLoc(c)  return vec(safe(function() return c:K2_GetComponentLocation() end)) end
local function compFwd(c)  return vec(safe(function() return c:GetForwardVector() end)) end

---------------------------------------------------------------------------
-- State (plain Lua values only: paths, numbers)
---------------------------------------------------------------------------
local state = {
    enabled = cfg.enabled,
    verbose = cfg.verbose,
    tick = 0,
    lit = {},        -- monster path -> accumulated lit seconds
    inBeam = {},     -- monster path -> true while it stays in a beam (for LIT logs/stats)
    missed = {},     -- monster path -> seconds since it was last seen in a beam (grace)
    blockLogged = {},-- monster path -> time of the last BLOCKED line (one every 5 s at most)
    nearState = {},  -- monster path -> last NEAR debug status
    pending = {},    -- monster path -> { id, label, ticks, player, retries } behaviour switch to verify
    noBeamWarn = {}, -- player name -> time of the last 'no SpotLight' warning
    lampState = {},  -- player name -> last detected lamp state (LAMP log lines)
    names = {},      -- monster path -> short name (logs)
    lastReact = {},  -- monster path -> tick of the last reaction
    stats = { lit = 0, reactions = 0, noise = 0, report = 0, spot = 0, flee = 0, attack = 0, losBlocked = 0 },
    losBroken = false,
    notHostLogged = false,
}

local function now() return state.tick * cfg.tickMs / 1000 end

---------------------------------------------------------------------------
-- Players and their beams
---------------------------------------------------------------------------
-- Is this player's lamp on? -> on, source
-- v1.0.2: in multiplayer the host never saw its friends' lamps (5 h game, every reaction
-- came from the host). FlashLightOn seems to change only on the owning client; what the
-- game sends to the host is the lamp intensity (OnRep_FlashLightIntensity), which drives
-- the beam everybody sees. For remote players the visible beam is used as well.
local function lampState(p)
    if readProp(p, cfg.flashlightOnProp) == true then return true, cfg.flashlightOnProp end
    if not cfg.remoteLampFromBeam then return false, "off" end
    if safe(function() return p:IsLocallyControlled() end) ~= false then return false, "off" end
    local c = readProp(p, cfg.flashlightComponent)
    if not valid(c) then return false, "no beam" end
    local inten = readProp(c, "Intensity")
    local vis = safe(function() return c:IsVisible() end)
    if type(inten) == "number" and inten >= cfg.remoteMinIntensity and vis ~= false then
        return true, "beam"
    end
    return false, "off"
end

local function fmtN(v)
    if type(v) == "number" then return string.format("%.1f", v) end
    return tostring(v)
end

local function playersLine()
    local parts = {}
    for _, p in ipairs(findAll(cfg.playerBaseClass)) do
        local c = readProp(p, cfg.flashlightComponent)
        parts[#parts + 1] = string.format("%s[local=%s %s=%s %s=%s beam=%s/%s]", shortName(p),
            tostring(safe(function() return p:IsLocallyControlled() end)),
            cfg.flashlightOnProp, tostring(readProp(p, cfg.flashlightOnProp)),
            cfg.lampIntensityProp, fmtN(readProp(p, cfg.lampIntensityProp)),
            valid(c) and fmtN(readProp(c, "Intensity")) or "none",
            valid(c) and tostring(safe(function() return c:IsVisible() end)) or "-")
    end
    return #parts > 0 and table.concat(parts, "  ") or "-"
end

local function litBeams()
    local beams = {}
    for _, p in ipairs(findAll(cfg.playerBaseClass)) do
        local on, source = lampState(p)
        if state.verbose then
            local pn = shortName(p)
            if state.lampState[pn] ~= on then
                state.lampState[pn] = on
                log("LAMP   %s %s (%s, %s)", pn, on and "ON" or "OFF", source,
                    safe(function() return p:IsLocallyControlled() end) == false and "remote player" or "local player")
            end
        end
        if on then
            local c = readProp(p, cfg.flashlightComponent)
            if valid(c) then
                local lx, ly, lz = compLoc(c)
                local fx, fy, fz = compFwd(c)
                local outer = readProp(c, "OuterConeAngle")
                local range = readProp(c, "AttenuationRadius")
                if type(outer) ~= "number" then outer = cfg.defaultConeAngle end
                if type(range) ~= "number" then range = cfg.defaultRange end
                if lx and fx then
                    beams[#beams + 1] = {
                        pawn = p, name = shortName(p),
                        lx = lx, ly = ly, lz = lz, fx = fx, fy = fy, fz = fz,
                        cosMax = math.cos(math.rad(math.min(89, outer * cfg.coneScale))),
                        cosClose = math.cos(math.rad(math.min(89, cfg.closeConeAngle))),
                        range = range * cfg.rangeScale,
                    }
                end
            else
                -- v1.0.1: per player, at most once a minute (seen once in a 5 h multiplayer game:
                -- probably a character spawning / dying / joining)
                local pn = shortName(p)
                local last = state.noBeamWarn[pn]
                if not last or now() - last >= 60 then
                    state.noBeamWarn[pn] = now()
                    log("WARNING: player %s has its lamp on but no '%s' component (spawning, dying or game update?)", pn, cfg.flashlightComponent)
                end
            end
        end
    end
    return beams
end

-- Is the monster inside the beam? -> distance (nil if not), distance, angle
-- v0.2.1: within closeRange the cone is wider (closeConeAngle): a monster in melee range
-- (Poulpi attacking / grabbing the head) has its centre far off the beam axis.
local function inBeam(b, mx, my, mz)
    local dx, dy, dz = mx - b.lx, my - b.ly, mz - b.lz
    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
    if d < 1 then return d, d, 0 end
    local cosA = (dx * b.fx + dy * b.fy + dz * b.fz) / d
    local angle = math.deg(math.acos(math.max(-1, math.min(1, cosA))))
    if d > b.range then return nil, d, angle end
    local limit = (d <= cfg.closeRange) and b.cosClose or b.cosMax
    if cosA < limit then return nil, d, angle end
    return d, d, angle
end

local function canSee(ctrl, pawn)
    if not cfg.lineOfSight or state.losBroken or not valid(ctrl) then return true end
    local ok, r = pcall(function() return ctrl:LineOfSightTo(pawn, { X = 0, Y = 0, Z = 0 }, false) end)
    if not ok or type(r) ~= "boolean" then
        state.losBroken = true
        log("WARNING: LineOfSightTo unavailable (%s) - walls are ignored from now on", tostring(r))
        return true
    end
    return r
end

---------------------------------------------------------------------------
-- Reactions
---------------------------------------------------------------------------
local ACTIONS = {}

function ACTIONS.noise(m, b, d)
    local cdo = safe(function() return StaticFindObject("/Script/AIModule.Default__AISense_Hearing") end)
    if not valid(cdo) then logOnce("nohearing", "WARNING: AISense_Hearing not found, 'noise' disabled") return false end
    local px, py, pz = actorLoc(b.pawn)
    if not px then return false end
    local ok, err = pcall(function()
        cdo:ReportNoiseEvent(b.pawn, { X = px, Y = py, Z = pz }, cfg.noiseLoudness, b.pawn,
            d + cfg.noiseExtraRange, FName(cfg.noiseTag))
    end)
    if not ok then logErr("noise", err) end
    return ok
end

function ACTIONS.report(m, b)
    local ok, err = pcall(function() m:BPI_BigRobot_ReportTarget(b.pawn) end)
    if not ok then logOnce("report:" .. className(m), "'report' not available on %s: %s", className(m), tostring(err)) end
    return ok
end

function ACTIONS.spot(m, b)
    local ok, err = pcall(function() m:BPI_BasicMonster_SetMainTarget(b.pawn) end)
    if not ok then logOnce("spot:" .. className(m), "'spot' not available on %s: %s", className(m), tostring(err)) end
    return ok
end

-- Force one of the game's behaviours (BPI_Monster_SwitchBehavior), after making the player
-- the main target (the escape / combat trees work from the current target).
local function switchBehavior(m, b, id, label)
    if readProp(m, "BehaviorType") == id then return false end  -- already doing it: nothing to do
    pcall(function() m:BPI_BasicMonster_SetMainTarget(b.pawn) end)
    local ok, err = pcall(function() m:BPI_Monster_SwitchBehavior(id) end)
    if not ok then logOnce(label .. ":" .. className(m), "'%s' not available on %s: %s", label, className(m), tostring(err)) end
    return ok
end

function ACTIONS.flee(m, b)   return switchBehavior(m, b, cfg.behaviorIds.escape, "flee") end
function ACTIONS.attack(m, b) return switchBehavior(m, b, cfg.behaviorIds.combat, "attack") end

function ACTIONS.ignore() return true end

local function react(m, cn, b, d, key)
    local list = cfg.reactions[cn] or cfg.reactions.default or { "noise" }
    local done = {}
    for _, a in ipairs(list) do
        local fn = ACTIONS[a]
        if fn then
            if fn(m, b, d) and a ~= "ignore" then
                if key and (a == "flee" or a == "attack") then
                    state.pending[key] = { id = (a == "flee") and cfg.behaviorIds.escape or cfg.behaviorIds.combat, label = a, ticks = 2,
                                           player = fullPath(b.pawn), retries = cfg.overrideRetries }
                end
                done[#done + 1] = a
                state.stats[a] = (state.stats[a] or 0) + 1
            end
        else
            logOnce("unknown:" .. tostring(a), "WARNING: unknown reaction '%s' in config", tostring(a))
        end
    end
    if #done > 0 then
        state.stats.reactions = state.stats.reactions + 1
        if state.verbose then
            local bt = readProp(m, "BehaviorType")
            log("REACT  %s -> %s  (lit by %s, %.0f cm%s)", shortName(m), table.concat(done, "+"), b.name, d,
                type(bt) == "number" and (", behaviour now " .. bt) or "")
        end
    end
end

---------------------------------------------------------------------------
-- Main tick (game thread)
---------------------------------------------------------------------------
local function tick()
    state.tick = state.tick + 1
    if not state.enabled then return end

    local beams = litBeams()
    local seen = {}
    if #beams > 0 then
        local dt = cfg.tickMs / 1000
        for _, m in ipairs(findAll(cfg.monsterBaseClass)) do
            if readProp(m, "IsDead") ~= true then
                if safe(function() return m:HasAuthority() end) == false then
                    -- replicated copy (client side, or a drone proxy): driven by the host
                    if not state.notHostLogged and safe(function() return beams[1].pawn:HasAuthority() end) == false then
                        state.notHostLogged = true
                        log("Not the host: monsters are driven by the host, LightSense does nothing here")
                    end
                else
                    local mx, my, mz = actorLoc(m)
                    if mx then
                        local key = fullPath(m)
                        -- closest beam that reaches the monster
                        local best, bestD, nearB, nearD, nearA
                        for _, b in ipairs(beams) do
                            local d, rawD, angle = inBeam(b, mx, my, mz)
                            if d and (not bestD or d < bestD) then best, bestD = b, d end
                            if rawD and rawD <= cfg.nearDebugRange and (not nearD or rawD < nearD) then nearB, nearD, nearA = b, rawD, angle end
                        end
                        local status = "out"
                        if best then
                            state.names[key] = shortName(m)
                            local ctrl = readProp(m, "Controller")
                            local close = bestD <= cfg.closeRange and cfg.closeIgnoreWalls
                            if close or canSee(ctrl, best.pawn) then
                                status = "lit"
                                seen[key] = true
                                state.missed[key] = 0
                                local before = state.lit[key] or 0
                                state.lit[key] = before + dt
                                if not state.inBeam[key] then
                                    state.inBeam[key] = true
                                    state.stats.lit = state.stats.lit + 1
                                    if state.verbose then log("LIT    %s by %s (%.0f cm)", shortName(m), best.name, bestD) end
                                end
                                local last = state.lastReact[key]
                                if state.lit[key] >= cfg.litSeconds and (not last or now() - last >= cfg.cooldownSeconds) then
                                    state.lastReact[key] = now()
                                    state.lit[key] = 0
                                    react(m, className(m), best, bestD, key)
                                end
                            else
                                status = "wall"
                                state.stats.losBlocked = state.stats.losBlocked + 1
                                local lastB = state.blockLogged[key]
                                if state.verbose and (not lastB or now() - lastB >= 5) then
                                    state.blockLogged[key] = now()
                                    log("BLOCKED %s: in the beam of %s (%.0f cm) but LineOfSightTo = false", shortName(m), best.name, bestD)
                                end
                            end
                        end
                        -- close-range debug: why is a monster near the player (not) lit?
                        if state.verbose and nearD then
                            local st = status .. (status == "out" and string.format(" (angle %.0f)", nearA or 0) or "")
                            if state.nearState[key] ~= status then
                                state.nearState[key] = status
                                log("NEAR   %s %.0f cm from %s's lamp: %s", shortName(m), nearD, nearB.name, st)
                            end
                        elseif state.nearState[key] then
                            state.nearState[key] = nil
                        end
                        -- did a forced behaviour stick?
                        local pend = state.pending[key]
                        if pend then
                            pend.ticks = pend.ticks - 1
                            if pend.ticks <= 0 then
                                state.pending[key] = nil
                                local bt = readProp(m, "BehaviorType")
                                if bt ~= pend.id then
                                    state.stats.overridden = (state.stats.overridden or 0) + 1
                                    -- v1.0.1: ask again once instead of waiting for the cooldown
                                    local pl = (pend.retries or 0) > 0 and safe(function() return StaticFindObject(pend.player) end)
                                    if pl and valid(pl) and ACTIONS[pend.label](m, { pawn = pl }) then
                                        log("OVERRIDDEN %s: '%s' asked, behaviour is %s 1 s later - asked again", shortName(m), pend.label, tostring(bt))
                                        state.pending[key] = { id = pend.id, label = pend.label, ticks = 2, player = pend.player, retries = pend.retries - 1 }
                                    else
                                        log("OVERRIDDEN %s: '%s' asked, behaviour is %s 1 s later", shortName(m), pend.label, tostring(bt))
                                    end
                                elseif state.verbose then
                                    log("KEPT   %s: '%s' still active 1 s later", shortName(m), pend.label)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- monsters out of the beams keep their lit time for litGraceSeconds (a blocked test
    -- or a step out of the beam no longer resets the count, v0.1.0 problem)
    for key in pairs(state.lit) do
        if not seen[key] then
            state.missed[key] = (state.missed[key] or 0) + cfg.tickMs / 1000
            if state.missed[key] > cfg.litGraceSeconds then
                if state.verbose and state.lit[key] > 0 then
                    log("LOST   %s (lit %.1f s, needed %.1f s)", state.names[key] or "?", state.lit[key], cfg.litSeconds)
                end
                state.lit[key], state.inBeam[key], state.missed[key] = nil, nil, nil
            end
        end
    end

    if state.verbose and state.tick % math.max(1, math.floor(30000 / cfg.tickMs)) == 0 then
        local s = state.stats
        log("STATS  lit=%d reactions=%d (noise=%d report=%d spot=%d flee=%d attack=%d) overridden=%d wallBlocked=%d",
            s.lit, s.reactions, s.noise or 0, s.report or 0, s.spot or 0, s.flee or 0, s.attack or 0, s.overridden or 0, s.losBlocked)
        log("PLAYERS %s", playersLine())
    end
end

local busy = false
LoopAsync(cfg.tickMs, function()
    if not busy then
        busy = true
        ExecuteInGameThread(function()
            local ok, err = pcall(tick)
            if not ok then logErr("tick", err) end
            busy = false
        end)
    end
    return false
end)

---------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------
local function bind(keyName, fn, label)
    local k = Key and Key[keyName]
    if not k then log("Unknown key '%s' for %s", tostring(keyName), label) return end
    local cb = function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then logErr(label, err) end
        end)
    end
    local mod = cfg.modifier and ModifierKey and ModifierKey[cfg.modifier]
    local ok, err
    if mod then ok, err = pcall(RegisterKeyBind, k, { mod }, cb)
    else ok, err = pcall(RegisterKeyBind, k, cb) end
    if not ok then log("Could not bind %s: %s", label, tostring(err)) end
end

bind(cfg.toggleKey, function()
    state.enabled = not state.enabled
    state.lit, state.inBeam, state.missed, state.blockLogged = {}, {}, {}, {}
    log("LightSense %s", state.enabled and "ENABLED" or "DISABLED")
end, "toggle")

bind(cfg.verboseKey, function()
    state.verbose = not state.verbose
    log("Verbose logs %s", state.verbose and "ON" or "OFF")
end, "verbose")

local prefix = cfg.modifier and (cfg.modifier .. "+") or ""
log("%s v%s loaded (%s). Log: %s", MOD, VERSION, state.enabled and "enabled" or "disabled", LOG_PATH)
log("Keys: %s%s enable/disable | %s%s verbose logs", prefix, cfg.toggleKey, prefix, cfg.verboseKey)
local parts = {}
for cn, list in pairs(cfg.reactions) do parts[#parts + 1] = cn .. "=" .. table.concat(list, "+") end
table.sort(parts)
log("Reactions: %s", table.concat(parts, " | "))
