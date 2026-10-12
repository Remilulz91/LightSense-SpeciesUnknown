-- LightSenseDiag - configuration (v0.3)
-- READ-ONLY diagnostic: nothing in the game is modified.

return {
    -- Game classes (found by AlliedDefense)
    playerBaseClass    = "BP_ParentCharacter_C",
    monsterBaseClasses = { "BP_ParentMonster_C", "BP_BaseMonster_C" },

    -- Keys (UE4SS Key enum) + modifier ("CONTROL", "SHIFT", "ALT" or nil)
    -- Chosen so they do not clash with AlliedDefense (Ctrl+F6/F9/F10/F11).
    modifier = "CONTROL",
    keys = {
        summary = "F2",  -- hook call counts + monster classes seen
        marker  = "F3",  -- numbered marker in the log (to tag your in-game actions)
        scan    = "F5",  -- dump: players, flashlights, monsters, AI controllers, blackboards, senses
        monitor = "F7",  -- change tracker ON/OFF (flashlight, monsters, blackboards, cone test)
        hooks   = "F8",  -- function spy ON/OFF  (turn it OFF before leaving a mission!)
    },

    -- Flashlight (found by v0.1 on BP_Character_C) ------------------------
    flashlightOnProp    = "FlashLightOn",   -- bool, true while the lamp is on
    flashlightComponent = "SpotLight",      -- beam (attached to SceneFlashlight): cone 45, range 2200
    flashlightProps     = { "FlashLightOn", "FlashLightIntensity", "FlashLightPower", "FlashlightCooldown" },
    defaultConeAngle    = 45,               -- used if the beam has no OuterConeAngle
    defaultRange        = 2200,             -- used if the beam has no AttenuationRadius

    -- Scan --------------------------------------------------------------
    scanPlayerClass = false,  -- true: dump the whole player class again (already done in v0.1)
    -- Property / function names highlighted with "**" in the dump (lowercase Lua patterns)
    highlightPatterns = {
        "light", "flash", "lamp", "see", "sight", "vision", "view", "cone", "hear", "noise", "sound",
        "bt", "behavio", "blackboard", "state", "target", "trg", "aggro", "agro", "alert", "detect",
        "search", "escape", "flee", "patrol", "combat", "chase", "follow", "stun", "scare", "fear",
        "percept", "sens",
    },
    -- Engine classes dumped on every level (not only Blueprint levels)
    fullDumpClasses = { "AIPerceptionComponent", "AISenseConfig", "PawnSensingComponent",
                        "AIPerceptionStimuliSourceComponent", "PawnNoiseEmitterComponent" },

    -- Monitor -----------------------------------------------------------
    monitorIntervalMs = 500,
    -- Only these properties are tracked (v0.1 tracked everything: 240 on the player)
    playerWatch  = { "FlashLightOn", "FlashLightIntensity", "FlashlightCooldown" },
    monsterWatch = { "CanSeeTarget", "InstantSee", "JustSeenA NewTarget", "IsEscaping",
                     "LastTargetActor", "LastMainTarget", "SeeThreshold", "HearSoundThreshold" },
    -- Logged with every "CONE IN" line
    monsterBriefProps = { "SeeThreshold", "CanSeeTarget", "InstantSee", "SeeDistance", "Vision Cone Angle" },
    floatStep = 0.5,                -- floats are rounded to this step (less noise)
    watchAllBlueprintProps = false, -- true: v0.1 behaviour (every simple Blueprint property, verbose)
    -- v0.3: every simple Blueprint property tracked for these classes only (Poulpi flee study)
    watchAllForClasses = { "BP_Monster_Poulpi_C" },
    monitorPropTypes = { "BoolProperty", "ByteProperty", "EnumProperty", "IntProperty",
                         "NameProperty", "ObjectProperty", "ClassProperty" },
    monitorIgnore = { "^ubergraphframe$", "^defaultsceneroot$", "deathtime", "stucktime", "^timeline", "sound", "voice", "anim", "montage" },
    monitorBlackboardVectors = false, -- true: also Vector blackboard keys (verbose)
    coneTest = true,            -- CONE IN / OUT when a monster enters / leaves a lit beam
    lineOfSightTest = false,    -- true: also call the monster controller's LineOfSightTo(player)
                                -- (engine call with a struct parameter: try it once the rest is stable)
    slowTickMs = 30,            -- log "SLOW monitor tick" above this duration

    -- Hooks -------------------------------------------------------------
    -- Monster / controller Blueprint functions spied when their name matches (lowercase patterns)
    hookPatterns = {
        "see", "sight", "vision", "hear", "sound", "noise", "search", "escape", "flee",
        "fear", "afraid", "scare", "panic", "run", "hide", "proba", "behavior", "behaviour",
        "target", "trg", "alert", "detect", "percept", "scare", "fear", "stun", "light", "flash",
    },
    -- Player Blueprint functions spied (flashlight toggle)
    playerHookPatterns = { "flash", "lamp", "torch" },
    -- Never hooked: per-frame / very frequent functions seen in v0.1
    hookExclude = {
        "^executeubergraph", "^receivetick$", "^userconstructionscript$", "tick",
        "^movefacetotarget$", "^increaseenergy$", "^decreaseseethreshold$",
        "^decreasehearsoundthreshold$", "^cancelanimduringcaptureescape$",
        "^bpi_monster_isseenewtarget$", "^bpi_footsteps_getsound$", "^canplaysoundfar$",
        "dispatch__delegatesignature$",
        "^shouldtargetting$", "^setlasttargetlocation$", "^bpi_bigrobot_targetcanbeshooted$",
        "^bpi_monster_getregisteredtargets$", "^bpi_bigrobot_shouldtargetting$",
        "^setbellylightintensity$", "^setenergylight$", "^seteyelightintensity$",
        "^bpi_bigrobot_playservossound$", "^foleysound$",
    },
    maxHooks = 100,              -- total (engine + Blueprint)
    logHookInstall = false,     -- true: one "HOOK +" line per installed hook
    hookDedupSeconds = 2.0,     -- an identical call is shown again only after this delay
    -- Engine functions spied (quiet = counted only). No more LightComponent hooks (v0.1 flood).
    nativeHooks = {
        { path = "/Script/AIModule.AIController:RunBehaviorTree" },
        { path = "/Script/AIModule.AIController:MoveToLocation", quiet = true },
        { path = "/Script/AIModule.AIController:MoveToActor", quiet = true },
        { path = "/Script/AIModule.BlackboardComponent:SetValueAsBool" },
        { path = "/Script/AIModule.BlackboardComponent:SetValueAsObject" },
        { path = "/Script/AIModule.BlackboardComponent:SetValueAsEnum" },
        { path = "/Script/AIModule.BlackboardComponent:SetValueAsVector" },
        { path = "/Script/AIModule.BlackboardComponent:ClearValue" },
        { path = "/Script/AIModule.AISense_Hearing:ReportNoiseEvent" },
    },
}
