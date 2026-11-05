# Light Sense — Species: Unknown

*Species: Unknown* mod: **the specimens react to the players' flashlights**, each one with
its own game mechanics. Aggressive monsters are attracted by the light, the timid Poulpi
runs away from it.

> **UE4SS Lua**, no Unreal Engine tooling required. Same family as
> [AlliedDefense-SpeciesUnknown](https://github.com/Remilulz91/AlliedDefense-SpeciesUnknown).
> Author: **Remilulz_91** — © 2026 Remilulz_91, all rights reserved.
> Idea: a friend's suggestion.
>
> **Download:** [Nexus Mods](https://www.nexusmods.com/speciesunknown/mods/21) ·
> [GitHub Releases](https://github.com/Remilulz91/LightSense-SpeciesUnknown/releases)

## Requirements

- Species: Unknown (UE 5.7)
- **RE-UE4SS experimental build** (the stable 3.0.1 release does not support UE 5.7),
  plus the UE5.7 signature file from Nexus ("UE4SS Signatures for Species Unknown").
- Mods are loaded through their `enabled.txt` file — no need to edit `mods.txt`.
- Installing any mod locks public lobbies (game rule since 0.25): solo / private games only.
- Multiplayer: monsters are driven by the **host**, so **only the host needs the mod**
  (friends without any mod can join a private game). Friends' flashlights are detected through
  their visible beam since 1.0.2 (to be confirmed in game).

## Install

### From a release (players)

1. Download `LightSense-vX.Y.Z.zip` from
   [Nexus Mods](https://www.nexusmods.com/speciesunknown/mods/21) or the
   [Releases page](https://github.com/Remilulz91/LightSense-SpeciesUnknown/releases).
2. Extract it into the UE4SS `Mods` folder, e.g.
   `...\Species Unknown\SpeciesUnknown\Binaries\Win64\ue4ss\Mods\`
   so that you get `ue4ss\Mods\LightSense\enabled.txt` and `ue4ss\Mods\LightSense\Scripts\`.
3. Launch the game. `LightSense.log` appears in the mod folder.

### From the sources (development)

```bat
tools\install.bat        :: copies the mods into ue4ss\Mods
tools\install-dev.bat    :: links them instead (edits are live, logs land in the project)
tools\uninstall.bat
```

If the game folder is not found automatically:

```bat
set SU_MODS_DIR=D:\SteamLibrary\steamapps\common\Species Unknown\SpeciesUnknown\Binaries\Win64\ue4ss\Mods
tools\install.bat
```

Check: the first line of `LightSense.log` must show the expected version.

## Keys

| Key | Action |
|---|---|
| **Alt+F10** | Enable / disable the mod |
| **Alt+F11** | Verbose logs on / off (`LIT`, `REACT`, `KEPT` / `OVERRIDDEN`, `NEAR`, stats every 30 s) |

Alt is used so the keys do not clash with AlliedDefense (Ctrl+F6/F9/F10/F11).

## Reactions

| Monster | Class | Reaction when lit |
|---|---|---|
| Zombies | `BP_Zombie_Simple_C`, `BP_Monster_ZombieMaster_C` | **attracted** (`noise`): a noise at the player, they come to investigate the light |
| BigRobot | `BP_BigRobot_C` | **attracted + hunts** (`noise` + `report`): the player is reported to it like its drones do, it switches to combat |
| Drones | `BP_SphereBot_C` | attracted (`noise`) |
| Poulpi | `BP_Monster_Poulpi_C` | **flees** (`flee`): the game's own escape behaviour |
| Any other monster | `default` | attracted (`noise`) |

Available actions in `mods\LightSense\Scripts\config.lua` (`reactions`, per monster class, combinable):

| Action | What it does |
|---|---|
| `noise` | `AISense_Hearing.ReportNoiseEvent` at the player (what the game does for gunshots and footsteps) |
| `report` | BigRobot only: `BPI_BigRobot_ReportTarget(player)` |
| `flee` | player becomes the target + `BPI_Monster_SwitchBehavior(2)` (escape, `BehaviorTree_Escape`) |
| `attack` | player becomes the target + `BPI_Monster_SwitchBehavior(3)` (combat, `BehaviorTree_Combat`) |
| `spot` | player becomes the main target only (the game then draws its reaction at random) |
| `ignore` | no reaction |

Other settings: `litSeconds` (1 s in the beam before reacting), `cooldownSeconds` (8 s between
two reactions of the same monster), `litGraceSeconds`, `lineOfSight`, `coneScale`, `rangeScale`,
`closeRange` / `closeConeAngle` / `closeIgnoreWalls` (melee range), `overrideRetries`,
`remoteLampFromBeam` / `remoteMinIntensity` (friends' lamps), `noiseExtraRange`...

## How it works

- A player's lamp is on when `BP_Character_C.FlashLightOn` is true; the beam is its `SpotLight`
  component (cone 45°, range 2200 cm). `FlashLight (Server)` sends the lamp state to the host,
  so the host sees every player's lamp.
- Every 0.5 s (host only), each living monster inside a lit beam (angle + range, and not behind
  a wall — `LineOfSightTo`) accumulates lit time. After `litSeconds` it reacts, then waits
  `cooldownSeconds`. Within 5 m the cone is wider (80°) and walls are not tested: a monster
  attacking the player has its centre far off the beam axis.
- No hooks: the mod only reads properties and calls a few game functions on the game thread.

### Monster behaviours

When a monster sees a player, the game draws a behaviour at random (`PROBA_SeePlayer`; the Poulpi's
"Fearfull" factor is 0.25) and applies it with `BPI_Monster_SwitchBehavior(n)`:
0 patrol, 1 search, **2 escape**, **3 combat**, 4 vent, 5 follow, 9 go far.
`flee` / `attack` call it directly, so the reaction to the light does not depend on that draw.

### Findings (LightSenseDiag)

- Monster vision is Blueprint code in `BP_BaseMonster_C` (`SeeDistance` 3500, `Vision Cone Angle` 75,
  `SeeThreshold`, `InstantSee`, `CheckTargetTrace`); hearing sense range 4000.
- Behavior trees are switched with `RunBehaviorTree` (e.g. `ZombieBase` -> `ZombieCombat`,
  `BigRobot_SearchPlayer` -> `BigRobot_Combat`).
- Drones report players to the BigRobot (`AgroBySphere`, `BPI_BigRobot_ReportTarget`).
- The BigRobot has an unused light-stun mechanic (`StuntLight`, `IsStunt`, `StuntLightValue`).

## Project layout

```
LightSense-SpeciesUnknown/
├── mods/
│   └── LightSense/          <- the mod (enabled.txt + Scripts/main.lua, config.lua)
├── archive/LightSenseDiag/  <- read-only diagnostic used to reverse the monster AI (not installed)
├── tools/                   <- install / install-dev / uninstall / find-mods (.bat)
└── .github/workflows/       <- release.yml: a pushed tag vX.Y.Z builds the release zip
```

## Changelog

- **1.0.2** — friends' flashlights: a 2 h 45 verbose multiplayer log showed that every reaction
  came from the host's lamp (`FlashLightOn` seems to change only on the owning client). Remote
  players now also count as "lamp on" when their beam is visible (`remoteLampFromBeam`).
  Verbose logs: `LAMP` lines when a lamp turns on/off (with its source) and a `PLAYERS` line
  every 30 s. `REACT` lines no longer print `TrivialObject` for monsters without behaviour number.
  First verbose data on SnowSpider, SmallLeech, DarkLeech, Eye, Ghost and Michel (default reaction, no error).
- **1.0.1** — multiplayer stable (5 h private game, host-only install, no crash). A forced
  `flee` / `attack` overridden by the game 1 s later is asked again once (`overrideRetries`).
  The "no SpotLight" warning now names the player and repeats at most once a minute.
- **1.0.0** — first stable release. Zombies and BigRobot are attracted by the light (fake noise,
  + target report for the BigRobot), the Poulpi always flees it (game's own escape behaviour).
  Melee-range detection (5 m: wider cone, no wall test). Tested in solo on zombie, BigRobot and
  Poulpi contracts without crash. Verbose logs off by default (Alt+F11).
- **0.2.2** — melee range raised from 3 to 5 m (`LineOfSightTo` often failed while the Poulpi attacked).
- **0.2.1** — melee-range detection; `NEAR`, `KEPT` / `OVERRIDDEN` log lines.
- **0.2.0** — `flee` / `attack` actions (`BPI_Monster_SwitchBehavior`); Poulpi set to `flee`.
- **0.1.1** — lit time kept for 1.5 s when the beam test fails briefly; `BLOCKED` / `LOST` logs.
- **0.1.0** — first version: detection + `noise` / `report` / `spot` reactions.

## Known limitations

- Michel, Eye, Ghost, SnowSpider and the leeches use the default reaction (attracted).
- Within 5 m, a monster behind a thin wall can be counted as lit (no wall test in melee range).
- Once its escape is over, the Poulpi draws its behaviour again: without the lamp it may still attack.
  Rarely (once in a 5 h game) the game puts it back in combat right after a forced escape;
  since 1.0.1 the escape is asked again once.
- Every game update may rename classes/functions: if nothing reacts, turn verbose logs on (Alt+F11)
  and look for `not available` / `WARNING` lines.

## Copyright and license

© 2026 **Remilulz_91** ([@Remilulz91](https://github.com/Remilulz91)). **All rights reserved.**

This project (code, configuration, documentation and release files) is the property of its author.
No open-source license is granted. You may download the releases and use the mod for your own games,
but you may **not**, without the author's prior written permission:

- copy, modify, redistribute or re-upload this project or any part of it (on Nexus, GitHub,
  Thunderstore, Discord or anywhere else), including in modpacks;
- claim it as your own, remove or change the author credit, or publish a "fork" / derivative mod;
- sell it or use it for any commercial purpose.

**Want to help?** Contributions, bug reports and ideas are welcome: contact the author first
(GitHub issue or [@Remilulz91](https://github.com/Remilulz91)). Any accepted contribution becomes
part of this project and is published only through this repository.
