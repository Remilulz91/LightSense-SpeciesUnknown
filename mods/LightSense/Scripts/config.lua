-- LightSense - configuration
-- Reload: restart the game (or Ctrl+R if UE4SS hot reload is enabled).

return {
    enabled = true,             -- state at startup (toggle in game: Alt+F10)

    -- How each monster reacts when a player's flashlight shines on it.
    -- A list of actions, applied in order:
    --   "noise"  : a noise at the player's position (the game's own hearing system):
    --              the monster comes to investigate the light source
    --   "report" : BigRobot only - the target is reported to it, like its drones do:
    --              it switches to combat and hunts the player
    --   "flee"   : the monster runs away with the game's own escape behaviour (BehaviorTree_Escape)
    --   "attack" : the monster attacks the player with the game's own combat behaviour
    --   "spot"   : the player only becomes its main target (the game then draws its reaction
    --              at random: escape, combat, follow... - v0.1 Poulpi setting, did not always flee)
    --   "ignore" : no reaction
    -- Class names come from the diagnostic (LightSenseDiag). "default" = any other monster.
    reactions = {
        default                   = { "noise" },
        BP_BigRobot_C             = { "noise", "report" },
        BP_Monster_ZombieMaster_C = { "noise" },
        BP_Zombie_Simple_C        = { "noise" },
        BP_Monster_Poulpi_C       = { "flee" },    -- timid: always flees the light
        BP_SphereBot_C            = { "noise" },   -- drones: they report players to the BigRobot themselves
    },

    -- Detection
    litSeconds      = 1.0,      -- a monster must stay in the beam this long before it reacts
    litGraceSeconds = 1.5,      -- it may leave the beam / be hidden this long without losing its lit time
    cooldownSeconds = 8,        -- minimum delay between two reactions of the same monster
    lineOfSight     = true,     -- walls block the beam (uses the monster controller's LineOfSightTo)
                                -- if the game crashes when a monster is lit, set false and report it
    coneScale       = 1.0,      -- x the beam cone angle (45 deg in the game)
    closeRange      = 500,      -- within this distance (cm) a monster is in melee range (v0.2.2: 300 -> 500,
                                --   LineOfSightTo often failed between 3 and 5 m while the Poulpi attacked):
    closeConeAngle  = 80,       --   wider cone (its centre is far off the beam axis when it is on you)
    closeIgnoreWalls = true,    --   and no wall test (LineOfSightTo fails when it touches the player)
    overrideRetries = 1,        -- if the game overrides a forced flee / attack 1 s later, ask again this many times
    nearDebugRange  = 500,      -- verbose: "NEAR" lines explain why a monster this close is (not) lit
    rangeScale      = 1.0,      -- x the beam range (2200 cm in the game)

    -- "noise" action
    noiseLoudness   = 1.0,
    noiseExtraRange = 300,      -- the noise is heard up to (distance to the lit monster + this) cm
    noiseTag        = "LightSense",

    -- Game classes / properties (found by LightSenseDiag)
    playerBaseClass     = "BP_ParentCharacter_C",
    monsterBaseClass    = "BP_ParentMonster_C",
    flashlightOnProp    = "FlashLightOn",
    flashlightComponent = "SpotLight",
    lampIntensityProp   = "FlashLightIntensity", -- logged in PLAYERS lines (verbose)
    -- v1.0.2: remote players (friends) also count as "lamp on" when their beam is visible with an
    -- intensity >= remoteMinIntensity (FlashLightOn may only change on the friend's own PC)
    remoteLampFromBeam  = true,
    remoteMinIntensity  = 1,
    -- v1.0.3: friends' beam direction = their aim as sent to the host (GetBaseAimRotation,
    -- includes looking up/down) instead of the light component orientation
    remoteAimFromView   = true,
    defaultConeAngle    = 45,
    defaultRange        = 2200,

    tickMs = 500,               -- detection loop (do not go below 500: faster loops crashed AlliedDefense)

    -- Keys (Alt+ so they do not clash with AlliedDefense's Ctrl+F9/F10/F11)
    modifier  = "ALT",
    toggleKey = "F10",          -- enable / disable the mod
    verboseKey = "F11",         -- verbose logs on / off

    verbose = false,            -- true: one log line per lit monster and per reaction + stats every 30 s
                                -- (toggle in game: Alt+F11)

    -- Behaviour numbers of BPI_Monster_SwitchBehavior (seen with LightSenseDiag on the Poulpi):
    -- 0 patrol, 1 search, 2 escape, 3 combat, 4 vent, 5 follow, 9 go far
    behaviorIds = { escape = 2, combat = 3 },
}
