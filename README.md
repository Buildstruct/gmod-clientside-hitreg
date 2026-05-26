## Clientside Hitreg for Garry's Mod

This is a rewritten implementation of client-side hit registration, which aims to eliminate instances of so-called "fake hits" (hits where you see blood impacts but deal no damage)

This only work with bullets though, not all kinds of traces, so this won't affect stuff like melee weapons and projectiles and such

It also comes with a **debug overlay** for visualizing your bullets server-side vs client-side, useful for debugging weapons, and assorted Source engine weirdness.

Steam Workshop link: https://steamcommunity.com/sharedfiles/filedetails/?id=2977785840

\* While this for buildstruct, its not a restriction for others to use this.\
\* Eventually this will be looked into being PR'ed into master.

### server cvars:

- `clhr_enabled 1` : master toggle for clientside hit registration.
  - When set to `0` the server falls back to vanilla hit registration.

- `clhr_shotguns 1` : allow shotguns to use clientside hitreg

- `clhr_targetbits 255` : bitfield for targets that are allowed for clientside hitreg (for if you want to exclude certain types of entities)

  - `1` - players
  - `2` - npcs
  - `4` - nextbots
  - `8` - vehicles
  - `16` - weapons
  - `32` - ragdolls
  - `64` - props
    - prop_physics, func_physbox, physics_cannister, combine_mine, gib
  - `128` - anything else 
    - this includes most entity-based targets that don't fit the above categories
    - disabling this disables hitreg for a lot of map entities

- `clhr_subtick 0` : subtick hitreg simulation (very experimental, not recommended)
  - video demonstration: https://youtube.com/watch?v=rCLgx5wj4zk

### server cvars (server-only):

- `clhr_tolerance 8` : hitpos tolerance for lag-compensated entities

- `clhr_tolerance_nolc 128` : hitpos tolerance for entities that are not lag-compensated

- `clhr_tolerance_ping 100` : when calculating hitpos tolerance, clamps ping to this max value

- `clhr_supertolerant 0` : the client is always right (not recommended for public servers)

- `clhr_nofirebulletsincallback 0` : prevent bullets from being fired inside the callbacks of client-registered hits
  - you may enable this if client-registered hits are causing some weirdness with certain implementations of bullet penetration

- `clhr_printshots 0` : print attempts at client-registered hits in the console (for debug purposes).
  - Set to 2 for even more verbose output.
  - This is more-so a legacy debugger, consider using the ones bellow.

### Debuggers

Client convars (each player toggles their own overlays):

- `clhr_debug 0` : master toggle for the debug overlay

- `clhr_debug_duration 5` : how long (seconds) each shot's wireframe lingers before fading out

- `clhr_debug_hitbox 0` : continuously render the local player's hitbox snapshot streamed from the server

- `clhr_debug_hitbox_duration 0.25` : lifetime (seconds) of each hitbox snapshot

- `clhr_debug_reveal 0` : continuously render the nearest player in the local player's view cone (server picks the target)

- `clhr_debug_reveal_duration 0.25` : lifetime (seconds) of each reveal snapshot

- `clhr_debug_rate 16` : tick rate at which periodic hitbox/reveal data is sent to clients

- `clhr_debug_reveal_dist 1024` : max distance a reveal target can be from the viewer

- `clhr_debug_reveal_cone 15` : reveal / shot-report cone half-angle in degrees

#### Visualization

- **White** boxes - entities the server considered for the bullet
- **Green** boxes - the specific hitbox the server resolved as hit
- **Red** boxes/lines - the client's predicted version of the same shot (vanilla / no CLHR outcome yet)
- **Cyan** boxes/lines/sphere - CLHR **accepted** the client's claim.
  - the sphere marks the server's resolved hitpos and a line from the client's claimed endpoint to it.
- **Yellow** boxes/lines - CLHR **rejected** the client's claim.
  - This includes the failure reasons of `Hitpos too far`, `Trace obstructed`, `Exceeded tolerance check`, etc.
- **Orange** lines - drawn between the client's and server's resolved hit points to highlight prediction deviation.

#### Integration

SWEPs can opt out by setting `SWEP.CLHR_Disabled = true`.

Entity classes can be excluded via `CLHR.Exceptions[class] = true` at any time after the addon loads.

- `CLHR.PreApply(ply, data)`: return `false` to skip CLHR processing for this bullet
- `CLHR.PostApply(ply, trace, dmginfo, info)`: return `false` to skip a specific bullet trace

When a successful client-registered hit occurs, the trace passed to subsequent callbacks has `trace.CLHR_CommandNumber` set to the user command number that originated the shot.
