# game-g2gfast

A bunny-hop and surf timer game in the competitive-shooter shape: the genre's
movement, its units, its cvars, a timer with zones an admin draws from the console, first and
third person, and every player drawn as an avatar.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and
each addon's own `CLAUDE.md` before working in it. This file is only about what this
game decides.

## What this game is, versus game-playground

game-playground is a sandbox that happens to have a surf ramp. This is the *timer
server*: the thing one of those communities would actually migrate to. Everything it
adds over the addons is one of four decisions, and the decisions are the file.

## Layout

```
game/
  g2g_units.gd      genre units → metres. The ONLY place the ratio lives
  g2g_config.gd     every cvar, in genre units, layered like every DotConfig
  g2g_movement.gd   G2GConfig → DotFpsTunables. The only place units cross
  g2g_game.gd       the simulation: maps, timers, boards, players. Headless
  g2g_player.gd     controller + rig + camera + timer, joined
  g2g_rig.gd        the visible character: attachment nodes for the avatar slots
  g2g_avatars.gd    the stock schema, stock parts, and a player's own avatar
  g2g_camera.gd     first and third person, with the genre's field of view
  g2g_hud.gd        clock, keys, speed in u/s, PRACTICE
  g2g_replays.gd    the best replay per map, track and style. What the ghost plays
  g2g_query.gd      what a server browser is told: map, tick rate, styles, the WR
  g2g_client.gd     one local player. Never loaded by a server
  g2g_module.gd     the DotServer bridge: sv_autobunnyhopping and friends, and
                    the netcode's owner on a dedicated server
  net/
    g2g_net_bridge.gd  joins a G2GGame to a DotNetManager. The ordering is the file
    g2g_player_net.gd  one player as a replicated entity; DotFpsNetSync's specs
    g2g_net_command.gd a DotFpsCommand as a DotNetInput
    g2g_net_link.gd    the @rpc surface, identical on both ends. Never edit one end
    g2g_events.gd      every event and request body, and the movement config's wire
    g2g_event.gd, g2g_request.gd  the two DotNetMessages: a kind and a body
  g2g_geometry.gd   boxes and ramps, in units
  g2g_map.gd        base for the built-in maps
  g2g_bsp_map.gd    base for an IMPORTED map: mesh, materials and zones from a
                    manifest. See Decision 11
  g2g_bsp_lightmapped.gdshader  albedo x the lighting the map's own compiler baked
  g2g_map_catalogue.gd  finds every map by looking. There is no list of maps
  g2g_stats.gd      every per-player number, declared once. See Decision 12
  g2g_awards.gd     achievements as rules over those ids
  g2g_progress.gd   dot-stats and dot-achievements, joined to the runs
  g2g_arsenal.gd    the deathmatch half's weapons, items and match rules
  g2g_combat.gd     dot-combat + dot-loadout + dot-match, as a layer over the timer
  g2g_hunters.gd    dot-npc + dot-npc-ai + dot-npc-ai-director, along the course
  g2g_props.gd      practice blocks, frozen, and what they cost a record
  g2g_vote.gd       dot-vote over the map catalogue. Replaces the rtv that was not one
  g2g_services.gd   dot-chat + dot-voice + dot-moderation, on a dedicated server
  g2g_identity.gd   dot-cloud + dot-auth + dot-user + dot-platform
  g2g_client_extras.gd  the client halves of chat and voice
  g2g_browser.gd    dot-browser's client half: !servers, and what a row says
npcs/               two hunters and the body they share
props/              three practice blocks, in the genre's 32/64/128 sizes
maps/               bhop_g2g_intro, surf_g2g_intro, and their .zones.json
  imported_map.tscn THE scene every imported map uses. In the build; the maps are not
  imported/<id>/    what tools/bsp_import.py wrote: <id>.bin, <id>.json, the lightmap
                    atlas and the textures. Data only -- no scene, no script.
                    Derived; gitignored; never hand-edited
  zones/<id>.json   what a .bsp does NOT say about itself: which volume is the finish,
                    and why. Hand-written, checked in, merged at import. See
                    Decision 11 and maps/zones/README.md
avatars/            six stock parts and the tint shader
scenes/
  g2g_server.tscn   what a dot-server loads. A G2GGame under a plain Node
examples/           headless_run (129), headless_net (90), dedicated (121),
                    headless_imported (25 per map, plus one per track and stage),
                    headless_maps (24), jitter_probe (4 configurations)
tools/              export_zones.gd — run after changing a map
                    bsp_read.py, vtf.py, bsp_import.py — Source .bsp to a map
                    import_maps.sh — import a whole directory of them, idempotently
                    bsp_preview.gd/.tscn/.sh — render an imported map and exit
```

**There is no `[input]` block in `project.godot`, and that is deliberate.** There was
one — `player_forward`, `player_back`, `player_left`, `player_right`, `player_jump`,
`player_crouch` — and nothing read any of them: [DotFpsSampler] keys off its own
`actions` dictionary of `dot_fps_*` names and `register_default_actions` adds them to
the [InputMap] at runtime for a project that has none. Six actions declared once and
read nowhere, which is the family's own detector for a setting that does not exist.
Removing them rather than wiring them up is what makes this game's client work
**inside another project**: it now ships in dot-server-setup-test's browser shell,
whose `project.godot` has no input actions at all, and a game that depended on its own
would have had no controls there.

The keys are therefore the sampler's defaults. Duck is **Ctrl**, not Shift — the
README said Shift for as long as the dead block did, and neither was ever true.

## Where this game runs, besides here

`dot-server-setup-test` vendors it: `setup.sh` copies `game/`, `scenes/`, `maps/` and
`avatars/` into that project, `content/g2gfast/game.yml` points at
`res://scenes/g2g_server.tscn` and `res://game/g2g_module.gd`, and the browser shell
maps content id `g2gfast` to `res://game/g2g.tscn`. That is the deployment shape — a
separate process, a real socket, a browser — and by this family's repeated lesson it is
where the bugs are. It found four; two of them are below and two were in other
repositories.

## Decision 1: everything the operator touches is in genre units

`sv_airaccelerate 1000`, `sv_gravity 800`, a run speed of 250 u/s, a surf ramp that is
"1024 wide at 60°". A bhop server operator knows what those mean and nobody knows what
19.05 m/s² is. So every cvar, every config field, every HUD number and every map file
speaks genre units, and **the conversion to the metres the simulation runs in happens
at exactly one boundary — `G2GMovement.tunables_for`** — with `G2GUnits` as the only
definition of the ratio. A conversion anywhere else is a second copy of the ratio, and
two copies drift.

The ratio is **1 unit = 0.01905 m** (0.75 inch), the scale the genre's maps were
built at, not the 1-inch
figure sometimes quoted. It is what the 72-unit hull, the 64-unit eye and every map in
the genre were built against; at the wrong scale a surf ramp is one the movement cannot
hold.

The jump is specified as a **launch velocity** (301.99 u/s) and converted to the height
the tunables want with `h = v²/2g` — 57 units under 800, the number every bhop player
knows — so it stays honest when an operator changes `sv_gravity`.

## Decision 2: auto-bhop is the server's, and the styles defer to it

`sv_autobunnyhopping` (`G2GConfig.auto_bhop`) is the setting this game exists to expose.
It reaches every player through `G2GGame.apply_movement`, which rebuilds the tunables
and hands them to everybody — **abandoning every run in progress**, because a run half on
one movement and half on another is a run on neither. Same rule as a tick-rate change.

**The shipped `DotFpsStyle.defaults()` force auto-hop ON**, which is right for a game
with no cvar and wrong here. The first version left them as shipped and
`sv_autobunnyhopping 0` reached every player's tunables and was then undone by the
style on top — silently. `_build_styles` now sets every style's `auto_hop` and
`easy_bhop` to `INHERIT`, except `prebhop`, whose whole identity is "no auto-hop".

**A movement cvar is validated before the config is written**, through the console's
own validator on a *copy* of the config. The first version wrote the field, validated,
and on failure returned — leaving the config invalid, after which every later cvar
wrote its field, found the config still invalid because of the first, and quietly did
nothing while the console reported them all as set.

### A thing that looked like a bug and is the genre's physics being faithful

A player holding jump from a standstill creeps at exactly 30 u/s — the air cap — for
ever. On the tick a jump fires the player is already airborne when acceleration runs,
so a held key never gets a ground-acceleration tick. Those games do precisely this
(`CheckJumpButton` runs before `WalkMove`), which is why every real bhop run begins with
a **prestrafe**. The headless suite's bot walks before it hops; an hour was spent
finding out why it had to.

## Decision 3: the genre's field of view, not Godot's

`fov_desired 90` is 90° **horizontal at 4:3**, and those games widen it on a wider
screen.
Godot's `Camera3D.fov` is vertical and fixed. `G2GUnits.source_fov_to_vertical`
converts through the 4:3 frame: 90 becomes 73.74° vertical, which on 16:9 shows 106.26°
horizontally — exactly what they show. Handing 90 straight to Godot gives 121° at
16:9 and a player who cannot aim and cannot say why. Tested to the hundredth of a
degree, with the naive number named so it stays a mistake.

`sensitivity` has its usual meaning too: degrees per count is `sensitivity × 0.022`, so a
player's 2.5 works unchanged.

**Third person is cosmetic.** `G2GCamera` keeps both cameras and flips `current`; the
first-person one culls the local rig's render layer so the player does not see the
inside of their own head, the third-person one sits on a `SpringArm3D` and draws
everything. The controller aims from the eye whichever is active.
`sv_allow_thirdperson 0` is server-side because third person sees over ledges first
person cannot, and it puts anybody already in it back.

## Decision 4: one avatar schema, two sources of parts

`G2GAvatars.schema()` is a real `DotAvatarSchema` — body, head, hat — and the rig has one
attachment node per slot. **A stock character and a player's own avatar from the
platform are the same thing at different addresses**: the six stock parts ship in the
build under `res://avatars/`, a platform part names dot-cloud content, and
`DotAvatarBuilder` does not care which it got. A player with no avatar gets
`stock_avatar(id)`, a real document over the same schema, deterministic in the id so the
same player is the same colour on every machine.

`DotAvatarSchema.conform()` **edits the document in place** and returns what it changed.
`G2GAvatars.apply` runs it on a copy, or a server that could not draw one part would
quietly rewrite a player's own avatar. A part from a newer client is dropped, never
refused: a player is never invisible because their hat is from the future.

## The maps, and how they are textured

Three of them now: `bhop_g2g_intro`, `surf_g2g_intro` and `bhop_g2g_stages`, plus whatever has been imported.

**The default is an imported map, and not one of the three.** `G2GConfig.initial_map` is `surf_mesa`. A straight line of blocks over a flat plane is what a *suite* should run — and every example here still names one explicitly — but it is not what a player arriving at a server should be met by. It also makes the imported half the default path rather than the one nothing reaches unless somebody types a map name, which is this family's own rule about deployment shapes: a built-in map is a scene and a script and can never fail to be there, and an imported map is data at a path that has to be found, parsed and built.

**`bhop_g2g_stages` is the first one that is a map rather than a fixture.** The other
two are a straight line of blocks and a pair of ramps: they prove the movement and there
is one thing to do in each, once. It is the Counter-Strike staged shape — five sections
with a line between each, one idea per section, so a player who fails knows which idea
they failed:

```
1  straight    blocks in a line, gaps growing.      Keep the speed.
2  the turn     the course bends 90 degrees.        Strafe through it.
3  the climb    blocks rising 24 units each.        Height costs speed.
4  the drop     a descent onto narrow blocks.       Do not overshoot.
5  the zigzag   blocks alternating left and right.  Both directions.
```

Everything is derived from `_course()`, which walks a position and a heading and returns
every block; the geometry and the zones both read that one list. On a map that *turns*
that is not a nicety — a hand-placed stage line on a course whose gaps somebody later
changes is a leaderboard nobody can compare, and nothing reports it: the run still
finishes, the splits are just taken somewhere else.

**And it had no finish, for as long as it has existed.** `_build` drew the finish pad 384 units along world -Z; `build_zones` placed the finish zone 384 units along the *course heading*, which the turn in stage 2 leaves at 90 degrees and every stage after it inherits. So the pad sits at -Z and the zone sits at -X, 543 units apart, overlapping by a 128 x 24 corner nothing lands on. A player ran the whole map, arrived on a pad drawn in the finish colour, stopped, and the timer counted on for ever. Nothing errored and nothing could: a run that has not finished is a legitimate thing for a run to be, and the pad was exactly where the geometry said to put it.

`_pad_centre()` answers "where is the finish" now and the geometry and the zone both call it — this map's own rule about `_course()`, applied to the one place that was still doing the arithmetic twice.

What let it survive is the more useful half. `headless_maps` asserted the zone set is well formed, `headless_run` asserted the sidecar matches, `headless_imported` drove a timer over the eight imported maps — **and every one of those checks is about the zones, not about the zones adding up to a run.** The check that says so has to cross from the zone set into the geometry, so it is a raycast: drop a ray down the middle of every START, END and STAGE volume and require it to land inside that volume. A zone hanging over nothing is a zone the run never reaches, and from inside the game it is indistinguishable from a map with no end zone in it. It fails on `bhop_g2g_stages` without the fix and passes with it.

The stale-list bug came along for the ride: `_test_zone_files_match` carried `["bhop_g2g_intro", "surf_g2g_intro"]` and there are three maps, so `bhop_g2g_stages` had never been checked against its own sidecar. The files happened to agree; the check was blind either way. It discovers now, which is what `tools/export_zones.gd` stopped carrying a list for.

Its bonus is a **surf** descent on a bhop map, deliberately. A bonus track is a whole
second route with its own records, and making it the same thing as the main route wastes
it; it is also the cheapest proof that a track is a route and not a game mode.

**Every stage zone carries a `destination`**, through `G2GMap.zone_stage`, because
dot-timer's `request_stage` hands the host the zone's destination and one drawn without
it resolves to `Vector3.ZERO` — a point in the sky over the start, reached with no error
at all.

**Surfaces are roles, not colours.** `G2GGeometry.box` used to take a `Color` and set a
flat `albedo_color`, so every surface in the game was one unbroken tone — which in this
genre is not cosmetic. A surf ramp is a plane ridden at 30 m/s and a bhop block is one
cleared in eight ticks, and both are judged by *how fast the surface is going past*; the
only cue for that is a repeating pattern with a known size. `G2GTextures` supplies one,
triplanar and in **world** space, so one square is 64 units — the grid this genre's maps
are built on — on every surface whatever its size. The old `COLOUR_*` constants are role
ids now and keep their names, so no map file changed.

## Decision 12: everything else this family ships, and the timer keeps running

This game had the timer, the movement, the maps and the boards. It now has the rest of
the family — twenty-six addons — and the rule every one of them was added under is the
same sentence:

> **A player who came to run must not be stopped by anything added for a player who
> came to do something else.**

That is not a slogan; it decides the shape of four of them.

```
game/
  g2g_stats.gd     every per-player number, declared once
  g2g_awards.gd    achievements as a document of rules over those ids
  g2g_progress.gd  the node joining the two to the game, and to nothing else
  g2g_arsenal.gd   two weapons, and why they are the genre's rather than an arena's
  g2g_combat.gd    dot-combat + dot-loadout + dot-match, as a LAYER
  g2g_hunters.gd   dot-npc + dot-npc-ai + dot-npc-ai-director, along the course
  g2g_props.gd     practice blocks, frozen, and what they do to a record
  g2g_vote.gd      dot-vote over the map catalogue
  g2g_services.gd  dot-chat + dot-voice + dot-moderation
  g2g_identity.gd  dot-cloud + dot-auth + dot-user + dot-platform
  g2g_client_extras.gd  the client halves of chat and voice
```

### Statistics are read, not counted a second time

`DotFpsStats` has counted jumps, perfect jumps, strafes and top speed on every
controller since dot-fps-controller was written, and dot-timer counts runs and records.
`G2GProgress` reads those out and files the **difference**; it measures exactly one
thing itself, which is distance, because nothing else does.

**The difference is not optional and the reason is this game's own.**
`G2GGame._on_player_finished` calls `controller.stats.reset()` on every finish, so
filing the total on each sample would file the whole history on every sample and then
start again from nothing. A total that went *down* is a reset, and the whole new value
is filed rather than a negative one — the same rule `DotAchievementStatsLink` applies
one layer up, for the same reason.

**A best time is `LOWEST`, and getting that wrong is a personal best of zero for
everybody.** dot-stats' `merge` takes the incoming value whole when there is nothing
held, which is the distinction between "held zero" and "never seen"; `Under Thirty` is
the achievement that shows what happens without it, and it carries a second rule
requiring a finished run precisely because *a missing stat reads as zero and "at most
30" is satisfied by having never played*.

### Deathmatch is a layer, not a mode

`sv_deathmatch` adds hitboxes, health, an arsenal and a scoreboard and **takes nothing
away**: the timer still runs, and a player who never presses fire plays exactly the
game they played before. Surf and bhop communities have run deathmatch on their own
maps for twenty years and the reason is that a map whose movement everybody has learned
is a map where a fight is about movement.

The weapons are the genre's rather than an arena's, and that is the whole design: a
one-shot pistol and a knife, hitscan, **no magazine and no reload**. Reloading takes a
hand off the strafe keys, and every second a player spends not strafing on a surf map
is a second they spend falling. The rate of fire is the cost instead. Spread is wide
when moving and tight when still, so the fastest player on the map is the hardest to
hit and the worst shot.

Three things in the wiring that are not obvious:

- **The entity id is the player's own id with the `u` taken off**, and the inverse is a
  lookup rather than `"u%d" %`. Two spellings of one id format are two ends of a
  serialisation that never meet, which this family has paid for twice.
- **The match carries no time limit.** The map's clock ends the map, and a second clock
  underneath it that ends the match is two authorities over one question — dot-vote's
  director already owns the first.
- **The ghost is not armed.** It is a replay: it cannot press a trigger, cannot be hurt
  in any way that means anything, and registering it would put a name on the scoreboard
  that never dies and never leaves.

### A timer map is a critical path, so the hunters have no navigation graph

A hunter cannot catch a runner who is running well — the fastest does 8 m/s and a bhop
player on a good line does forty. What a hunter punishes is **stopping**, which is what
the timer already punishes, made visible.

`DotNpcDirectorFlow` is literally "the map's own critical path" as a thing a position
can be measured along, and a timer map *is* one: start pad, stage lines, end zone. So
the route is built from the map's own zones — the same list `bhop_g2g_stages` derives
its geometry from — the director spawns **ahead** along it, and a hunter with nothing to
chase patrols it. The pathfinding a mesh would give is spent on a map whose route is
already known.

`require_navigable_spawn` is therefore **off**, and it has to be: there is no graph, so
a navigable-spawn requirement would refuse every spawn on the map.

### Blocks are frozen, and they cost you the record

What a records community actually places is a practice line, a temporary block on the
section everybody fails, and a marker at the spot people keep asking about. Every one
of those wants to stay where it was put, so a prop here is spawned **frozen** — the
opposite default from a sandbox's, and the reason `g2g_prop_body.gd` has a
`starts_frozen` export at all.

**`only_practice` is on, and it is what makes the feature safe to ship.** A board with
one time set over a placed block is a board nobody trusts, and the alternative —
trusting an admin to clear up — is a rule enforced by memory. The sizes are 32, 64 and
128 units, the grid this genre's maps are built on, converted at the one boundary
`G2GUnits` owns.

### The vote this game shipped with was not one

`G2GGame.rock_the_vote` forwards to `DotMapTimeLimit`, which counts votes against a
fraction and expires the map: a countdown and a tally. `G2GVote` is the ballot a
records community actually runs — nominations with caps and seconding, an instant
runoff so a six-option vote is not won by a fifth of the server, a cooldown, and an
**extend** option, because a player two stages into a run they have been learning for an
hour should not lose the map to a clock.

Two decisions in it:

- **`begin_on_apply` is off.** The map session's own `changed` is the one signal that
  says what is running, because it fires for an admin typing `g2g_map` as well. Both
  firing means two entries in the play history for one play, and a "not in the last
  five maps" cooldown that is quietly two or three.
- **The ghost is not a voter.** `_player_count` excludes it, because otherwise a
  one-player server passes a quorum of two and can rock the vote on its own.

### Chat is the policy; dot-server stays the transport

`G2GServices` hooks `player_chat` and **cancels** it, routes the text through
`DotChatRouter`, and hands each recipient's line back to dot-server's manager to put on
the wire. Exactly one of the two delivers a line, which is what stops them being two
chat systems.

The channel that is about this genre is `running`: everybody who is mid-run. It is a
`MEMBERS` channel and the membership rule — "their timer is going" — is a thing only
this game knows, which is exactly why dot-chat asks rather than deciding. The team key
falls back to it, because a timer server has no teams and a team message on one reaches
the single player whose team number matches.

**dot-moderation is built first, and the order is load-bearing.** It publishes
`dot_mute_source` on `_ready` and both routers look that name up when they start; a
router that started first would find nothing, warn once, and enforce no gag for the life
of the server. It is here at all because dot-server's mute is two booleans on a session
object and a session dies with its connection — on a records server that matters more
than usual, because a gag is how an admin stops somebody spamming `!wr` at everybody.

**Voice rides its own channel on the link.** A talk spurt is fifty frames a second per
speaker relayed to every listener; on the state channel it would sit in the same ordered
queue as the snapshots, so somebody holding the talk key would add a frame of latency to
everybody's movement — and on a server where a run is counted in ticks, latency must not
depend on whether anybody is talking. The speaker id is stamped from the transport's
sender and never read out of the payload.

Its default channel is **ALL**, which is the opposite of game-arena's, and both are
right: an arena is a room, and a course is long and thin with half the server two
hundred metres away.

**UDP on a desktop and TCP in a browser, and neither is chosen anywhere.** The two
voice calls are declared `unreliable`, which is what voice wants: a lost frame is 20 ms
of silence a jitter buffer conceals, and a resent one arrives after the frames either
side of it have already played. What that becomes on the wire is `DotTransportAuto`'s
decision, and it has one sensible answer either way — ENet honours the unreliable
channel as UDP, and a browser has no UDP at all, so WebSocket delivers it reliably and
in order over TCP whatever anybody asks for. The platform rule falls out rather than
being written, and neither game names a transport.

### The server browser, from the other end

`G2GQuery` has contributed the map, the tick rate, the styles and the world record
since the module was written, and **nothing had ever read any of it**. `G2GBrowser` is
dot-browser's client half: the list model, three protocols, local filters, favourites
and history — and `dedicated` now has a real browser ask a real `DotServer` over a real
UDP socket, which is the seam the family's notes name as untested.

Two things a reader of a query section gets wrong once, and both were got wrong here
first:

- **The map is not `entry.map`.** That is dot-server's `info.map`, which means "the
  content id of the loaded game" and is empty on a server that never switches games.
  dot-browser nests a game's own section under `rules["game"]` precisely so a game
  putting a field called `map` in it cannot overwrite the other one.
- **JSON has one number type.** `tick_rate` is contributed as an int and comes back as
  a float, so `game_field(entry, "tick_rate")` is `"100.0"`. `game_number` is the
  accessor; `wr` is a dictionary and has a third.

The list is a chat command rather than a screen — `!servers`, or F3 — because that is
what this genre's fingers already do, and because this client has a HUD and a keyboard
rather than a [DotScreenStack]. game-arena has the screen. The same addon does the same
work either way; where it is drawn is the half a game is supposed to decide.

## Validating

```bash
godot --headless --path . --import
godot --headless --path . --script tools/export_zones.gd
godot --headless --path . res://examples/headless_run.tscn   # 129 checks
godot --headless --path . res://examples/headless_net.tscn   # 90 checks
godot --headless --path . res://examples/dedicated.tscn      # 121 checks
godot --headless --path . res://examples/jitter_probe.tscn   # 4 configurations
godot --headless --path . res://examples/headless_imported.tscn  # 25 per map, +1 per stage
godot --headless --path . res://examples/headless_maps.tscn      # 24 checks
```

`headless_maps` is the one that says there is no list of maps anywhere: it removes a
map from the catalogue that is still on disk and checks a rescan puts it back, and adds
one to the catalogue that is *not* on disk and checks a rescan takes it away. Counting
three maps proves nothing — a hardcoded list of three counts three too.

`headless_imported` skips cleanly when `maps/imported/` is empty, because an imported
map is optional content and a fresh clone that has never run the importer is not
broken. It iterates whatever is there rather than naming a map, for the reason the
catalogue does.

Its last two sections are the ones that say a map is a **level**. `_test_runnable`
drives a `DotTimer` over the map's own zone set and asserts a time comes out with every
split in it; `_test_stands_where_it_sends_you` teleports a player to each track's spawn
and each `!s<n>` destination and waits to see whether they are still there a second
later. A zone set can pass `problems()`, have no thin volumes and still be impossible to
finish, and a stage destination that is in the sky succeeds at every step and drops the
player out of the world.

`tools/bsp_preview.sh` renders each of them from its spawn, because four of the bugs in
this family's list were found by looking at a picture. It uses `xvfb-run`: `--headless`
gives a null renderer and saves a frame of nothing, which is worse than no screenshot
because it looks like one.

`jitter_probe` is the only one that measures a **rendered frame** rather than a
simulated tick, which is the whole class of bug the others cannot reach. See
Decision 10.

**Two checks in `headless_run` were measuring the wrong thing and only stopped when
dot-timer was fixed.** `DotTimer.effect_requested` was emitted by nothing, so this
game's maps had respawn zones that did nothing and a bot that missed the ramps fell out
of the level and kept falling. "Most of the descent is spent not grounded, which is
surf" was counting 1500 ticks of a bot nowhere near the map, and passed comfortably.
The bot is now put back on the start platform after about 500 ticks; the loop stops
there, is airborne for 94% of them, and the suite asserts the pit fired at all. The
bhop test's fixed 420-tick prestrafe had the same problem and now drives until the run
starts.


`headless_net` runs a server game and a client game in one process over a lossy
loopback: admission, prediction converging, the timer and a finish replicated to the
sub-tick fraction, a cvar changed under a live client, styles, tracks, a published
avatar, a map change, a bot, and leaving.

`dedicated` configures the server for **100** ticks in `server.cfg` — deliberately not
the project's 128 — and checks the game and the timer count at 100, because a test
using the same number at both ends would pass with the chain disconnected.

## Decision 5: the movement configuration travels, not the tunables

`G2GNetBridge` sends a joining client the server's `G2GConfig` movement fields
(`G2GConfig.MOVEMENT_FIELDS`) and both ends derive `DotFpsTunables` through the same
`G2GMovement.tunables_for`. The alternative — sending the tunables — is one more
representation that can drift, and prediction only converges when the two ends
simulate with identical numbers. The server fingerprints what it derived and the
client compares; a mismatch is one log line rather than "the netcode feels bad".

That is also why `G2GConfig.snap_movement()` exists and why `G2GGame` calls it before
deriving anything: the wire carries float32, and a server simulating with the doubles
it read from a file while its clients simulate with what they received differs in the
last bit, silently. The values are rounded once, on the server, before anything reads
them.

The bridge is modelled on dot-2d-hungry's, the one in this family proven over a real
socket. What is specific to this game:

- **The tick is a whole-game property.** dot-net simulates per entity; here everybody
  moves and then every timer is fed the position its move produced. The first
  behaviour through on a tick runs the whole game (`ensure_game_ticked`); the rest find
  it done. The client's `client_tick` does the same for what it predicts and then feeds
  every timer, so a remote player's clock on your HUD advances with theirs.
- **Timers replicate as run identities, not per tick.** `DotTimerNet.RunState` carries
  the start tick and the sub-tick fractions; the client's clock does the counting
  between packets. A finish carries ticks and fractions, and the client reproduces the
  server's arithmetic to the digit — `headless_net` compares them at 1e-4 s, which is
  how it found `DotTimerNet.Finish.time()` subtracting the end fraction the run adds.
- **A peer receives nothing until it says READY.** dot-server's signon finishes and
  *then* the client builds its scene; a HELLO sent in between lands on nothing.
- **Bots are session ids without a peer.** Peer 0 is dot-net's broadcast address, so
  a bot is never a peer; `remove_player` handles both, `remove_peer` delegates.
- **A player's avatar comes from dot-platform's admission** (`G2GModule._avatar_for`,
  duck-typed through the `platform` module) and, failing that, from what the client
  publishes (`G2GClient.avatar`), and failing that the stock one. Every one goes
  through `G2GRig.dress`, which conforms it to the server's schema.

## Decision 6: the record's ghost is a player

The replay bot every community timer has: the server record's replay runs the map
as a `G2GPlayer`
with `replay` set and no timer. That one choice does three jobs. It draws through the
same rig everybody else does; it replicates through the same bridge, so a client —
browser included — sees the run without ever decoding a replay; and it counts as a
bot in the server query, which is what it is.

`sv_replay_bot` turns it on and off live, and off takes the current ghost away rather
than waiting for the next map — an operator who turns a bot off wants it gone now.
`g2g_ghost` says whose record is running and how far through it is.

`G2GReplays` keeps the fastest replay per map, track and style, in memory always and
on disk beside the records when there is a directory, using `DotTimerReplay`'s own
file format — so a replay set at 64 Hz plays on a 128 Hz server. **A replay is kept
only with an accepted record**, never with a merely faster run: a checkpoint-assisted
or tainted run is not a record and must not become the ghost everybody chases.

The bridge adopts any player the game made itself (`player_added`) as an entity with
no peer, and `ensure_game_ticked` applies received commands **only to players that
have a peer** — a bot is driven by something else, and an empty command applied on
top of a replay stands the ghost still. That rule was found by `dedicated`, whose
driven bots stopped hopping the moment the bridge started adopting them.

`!r`, `!wr`, `!top`, `!style`, `!track`, `!rtv` are chat triggers as well as console
commands, because twenty years of bhop servers taught everybody's fingers those.
`g2g_map` is not: changing the map from chat is an admin's, through the console.

## Decision 7: the client counts at the SERVER's tick rate

`HELLO` carries `tick_rate` and always did. Nothing read it back out.

`G2GGame._resolve_tick_rate` takes `Engine.physics_ticks_per_second`, which on a server
is `sv_tickrate` and on a client is whatever the host project exported — 128 in this
repository, **60 in dot-server-setup-test's browser shell, which never sets one**. So a
client simulated at a rate the server did not, and three things are derived from that
number: the step prediction replays with, the divisor every replicated run time is
reconstituted through, and `DotNetClock`'s own rate.

Measured, by putting `headless_net`'s client on 60 against its 128 server: **correction
rate 0.96** — prediction never converging — and the client's clock reading a finish as
0.466 s where the server filed 0.218 s, which is 128/60 of it. On a leaderboard that is
every time on the board wrong by the ratio of two numbers nobody thought were related.

`G2GNetBridge._adopt_tick_rate` now applies it before `sync_from_server`, because the
clock converts its error and its input lead through `tick_rate`. All three copies move
together: `G2GGame.set_tick_rate` (which takes the timer manager with it and reads the
rate back rather than assigning it), `net.config.tick_rate`, and `net.clock.tick_rate`
— the last one being a copy taken at `setup()` that writing the config does not touch.

**`headless_net` could not have found this and now can.** Both halves run in one
process, so they read one `Engine.physics_ticks_per_second` and agreed no matter what
the wire said; the check that asserted "at one tick rate" was passing for that reason
rather than for a good one. The suite now puts the client on 60 deliberately, the way a
host project would, and asserts that HELLO is what corrects it.

The same shape found two more, both only visible in a browser:

- **A client's own configuration was invalid.** `G2GClient` clears `initial_map` when it
  is networked — correct, the server decides — and `G2GConfig.validate()` refused an
  empty one unconditionally, so `load_layered` failed and every networked client logged
  "the g2gfast configuration is not usable". Only an authoritative instance chooses a
  map.
- **dot-timer warned every client that its times would be wrong.** The rate/engine
  mismatch warning is real on a server and meaningless on a mirroring timer, which
  counts at the rate it was told precisely so a run set at 128 is comparable on a client
  rendering at 60. It is now guarded on `authoritative`.

## Decision 9: the local player is adopted, not looked up

`HELLO` says who you are. `JOIN` is what creates you — `G2GNetBridge._apply_join` calls
`game.add_player` — and it arrives afterwards. So `G2GClient._watch`, called from
`hello_received`, resolved `game.players.get(id)` **one message too early**, got null,
and never tried again: [member G2GClient.player] was null for the entire session on
every networked client.

**What that broke is a strange list, and the strangeness is the point.** The HUD binds by
id, so it worked. The camera follows the entity, so it worked. Movement worked, because
`DotFpsSampler.sample` polls the [InputMap] rather than reading events. What did not work
was everything below the `player == null` guard in `_unhandled_input` — **mouse look, F5,
Tab, R, C, V and M**. A client that connects, draws, shows a live HUD and walks around,
on which the mouse and the whole keyboard do nothing.

`_on_player_added` is the fix: connect [signal G2GGame.player_added] before anything can
create a player, keep the id in `_watch_id`, and adopt when the player named by it
appears. `_adopt` is also where the sampler is put on the player's tunables, which
`_on_hello` used to attempt against the null it had just fetched.

`headless_net` drives two bridges directly and never instantiates `G2GClient`, so nothing
in the suite had been through this. It now asserts the ordering the bug lived in — that
the local player does **not** exist when HELLO names it, and that `player_added` fires for
it — which is what a client has to be written against.

**How it was actually confirmed.** Not by a test: Playwright cannot move a pointer-locked
mouse — `movementX`/`movementY` come through as `0` on every synthetic event — so the
symptom the player reported is not directly reproducible in the harness. F5 is, and it
sits in the same `match` under the same guard: press it, screenshot, and third person is
either drawn or it is not. *When the thing you want to test is unreachable, test the
thing beside it that shares the failure.*

## Decision 10: the client draws BETWEEN ticks, and the engine runs at the server's rate

Reported as "very jittery in the browser", and every number in every suite was right.

The simulation was already correct. `G2GClient._physics_process` asks
`DotNetClock.advance` how many ticks a frame is worth, so a client on a 60 Hz engine
against a 128-tick server ran exactly the right ticks — **in bursts of two and three**,
2.133 of them per physics frame. Nothing rendered between ticks: `G2GPlayer.present`
drew `controller.state` directly, so the camera advanced 74 mm on six frames out of
seven and 112 mm on the seventh. **A 47% change in apparent speed, eight times a
second**, for as long as a browser client has existed.

Two halves, and **either one alone measures as no better than doing nothing**:

- **`DotFpsController.render_state` exists and nothing called it.** It has interpolated
  between the last two ticks since the controller was written, and its guard was
  `if drive != Drive.LOCAL: return state` — LOCAL being the one drive no networked game
  uses. So the cure was written, documented as the cure, and unreachable from every
  deployment shape that needed it. `_accumulator` is never advanced under EXTERNAL
  either, so even reaching it would have blended at a constant alpha of zero.
- **`_adopt_tick_rate` moved three copies of the tick rate and not the engine's.** The
  fraction a renderer interpolates at is a fraction through a *physics frame*, which is
  only a fraction through a tick while the two rates agree. At 60-against-128 the
  interpolation changes nothing measurable.

`examples/jitter_probe.tscn` runs all four combinations and fails unless exactly the
shipped one is smooth — because a probe that only tested the fix would have passed for
either half on its own.

| | drawn at the last tick | drawn between ticks |
| --- | --- | --- |
| **engine 60** | 47% spread | 47% spread |
| **engine 128** | 47% spread | **0%** |

**View angles are deliberately still not interpolated**, and they never juddered: mouse
motion is delivered once per frame and `DotFpsSampler.sample` consumes everything
pending, so whichever tick runs next absorbs exactly that frame's motion and the yaw
tracks the mouse per frame however many ticks ran. Blending it would add a tick of
latency to aiming to fix nothing.

The cost is real and worth naming: a browser client now steps Godot's physics 128 times
a second instead of 60. The work inside the tick is unchanged — the clock was already
producing 128 ticks a second — so what is added is the engine's own physics step, which
for a world of static geometry and one query-driven controller is close to free.

**Nothing headless could see any of this**, which is why it survived every suite:
every check in this repository asserts a simulated value, and every simulated value was
correct. `jitter_probe` is the first thing here that samples what a *frame* shows.

## Decision 8: the browser is asked for the mouse, not told

`G2GClient._ready()` set `Input.mouse_mode = MOUSE_MODE_CAPTURED`, which is right on a
desktop and impossible in a browser: pointer lock needs **transient user activation** —
a real click — and `_ready()` is the one moment in a client's life guaranteed not to
have one.

It is refused *silently*. `Input.mouse_mode` reads back as CAPTURED, the view still
turns with the mouse, and nothing anywhere reports a problem; what the player gets is a
cursor sitting on top of the game that wanders out of the window mid-run.

**This is the family's deployment-shape rule on a capability nothing had needed yet.**
game-hungario is the only other browser client in the family and it is 2D — it reads the
cursor's position and never locks it — so g2gfast is the first thing here that has ever
asked a browser for pointer lock, and the first place this could have been found.

- Desktop captures immediately. A player who launched a first-person game should not
  have to click their own window first.
- Web shows the cursor, says "Click to play" on the HUD, and captures on the first
  mouse-button press. That press is handled *before* the `player == null` guard, because
  a browser player clicks while the world is still loading more often than not, and a
  click swallowed for want of a player is a click that never captures anything.
- Escape **releases** and does not toggle, on both platforms. Escape is how a browser
  itself exits pointer lock and it then refuses to re-enter for about a second, so a
  toggle bound to it silently does nothing every other press on the web. One key that
  releases and one gesture that captures is the same contract everywhere — and it is
  what this file's own class documentation had claimed all along while the code toggled.

Verified with a real click in headless Chromium: `document.pointerLockElement` is null
before and set after. `tools/browser_check.mjs` never clicks, which is why nothing had
exercised this.

## Decision 11: a Source map is content, and it is read rather than rebuilt

`tools/bsp_import.py` turns a Counter-Strike: Source `.bsp` into a map this game
loads: geometry, the textures the file carried inside itself, the lighting its
compiler baked, its start line, its finish, its stages, its bonus tracks and the
volumes that catch a player who fell off the ride. It was written against
`surf_kitsune` and `Surf_Mesa` in `godot/inspirations/`, and now runs over the eight
maps there.

**The scale is not converted, because there is nothing to convert.** Source stores map
coordinates at 0.75 inch per unit and [G2GUnits] already declares exactly that ratio,
for exactly this reason — a surf ramp imported at the 1-inch figure is a ramp the
movement cannot hold. A BSP coordinate *is* a genre unit. The whole transform is the
axis swap, because Source is Z-up and Godot is Y-up:

    godot = (src.x, src.z, -src.y)

**START and END zones are read, not guessed — and where there is nothing to read they
are written down by hand.** The paragraph that stood here said a CS:S map has no
convention for a start and a finish that survives compilation. That is true of
`surf_kitsune`, which really does drive its stages with
`OnTrigger !activator,AddOutput,targetname X` and a filter chain, and it was false of
five of the eight maps beside it, which carry `zone_start`, `map_end_zone`,
`startzone_s4`, `tm_bonus2_endzone` and `tm_checkpoint1` in the entity lump in plain
text, because they were built for a timer. **Reading a label the mapper wrote is not
guessing, and throwing it away cost every one of those maps its timer.** `zone_role()`
is the whole rule; `assign_tracks()` turns `bonus2`, `koga` and `b_` into track
numbers.

Three of the eight label nothing, and for those — and for the halves the labelled ones
are missing — there is **`maps/zones/<id>.json`**: one file per map, checked in, saying
which volume is the finish and *why*, in terms of what is in the .bsp rather than in
coordinates somebody typed. A zone there names its volume as an entity
(`"named": "startzone_s4"`), as the teleport aimed somewhere (`"teleport_to":
"endroomdest"`), as a box grown around a destination, or as the nearest trigger to a
point; anything that fails to resolve **stops the import**, because a finish line that
quietly resolved to nothing is a map nobody can finish and nothing about playing it
would say so. `maps/zones/README.md` is the format.

That directory is beside the repository and not beside the import for one reason:
`tools/import_maps.sh --force` rewrites every manifest, so a hand-written zone kept in
one would survive exactly until somebody re-imported the map it describes.

**A track with a start and no end is dropped, and said so.** `surf_summit`'s third
bonus has a start zone, eight checkpoints and no finish anywhere in the map. Left in,
it is a track a player can begin and never complete and one `DotTimerZoneSet.problems()`
refuses the whole map over; dropped silently it is a bonus that quietly does not exist.

**A teleport is the pit unless the map says otherwise.** Every `trigger_teleport` left
after the zones have claimed theirs becomes `DotTimerZone.Kind.RESPAWN`, which is what
it always was and the reliable half. `surf_kitsune` is where that is not enough: all 53
of its teleports aim at one of nine colour destinations, and the ones the size of a
room are the pit under that colour's section while the ones the size of a door are how
you leave one section for the next. Treated alike — which is what "every teleport is a
RESPAWN" does — **walking out of the first section ends the run and puts the player back
at the start, for ever.** `"doorways": {"max_horizontal": 512}` in the map's own file
opts into the measurement that separates them, and the doors become
`Kind.TELEPORT`, which keeps the run. It is opt-in because it is only true of a map
whose sections are joined by doors.

**The mesh is a binary and not a glTF, and the reason is one array.** The baked
lighting needs `ARRAY_TEX_UV2` to reach the shader, and every route through an
importer decides for you what a second UV set means: glTF's occlusion channel is
greyscale, so the coloured neon that is `surf_kitsune`'s entire character goes grey,
and its emissive channel is additive, so it washes out. Building the [ArrayMesh] from a
`PackedByteArray` costs one pass and keeps this repository's own convention anyway —
maps here are made in code.

**Imported maps are discovered, not listed.** `G2GMapCatalogue.scan` scans
`maps/imported/` for manifests. The three hand-written maps above it are a list because
they cannot appear without somebody editing this repository; an imported one arrives by
running a script, and a second place to remember it is the shape that has gone stale
four times in this tree — `setup.sh`, `tools/check.sh`, `package_check.sh` and the
bootstrap manifests. The manifest cannot be forgotten, because the map does not load
without it.

### What building it found

- **`dmodel_t` is 48 bytes and reading it as 52 still produces a perfect world.**
  Model 0 is the first record, so every field before the overrun lands correctly: the
  map rendered flawlessly, at the right scale, with correct materials — and every one
  of the 92 brush models after it was misaligned, so all 53 trigger volumes were
  garbage. Nothing errored, because a wrong AABB is a legitimate AABB. It showed only
  because the sizes came out **negative**. The family's own "a value produced correctly
  and consumed by nothing", with the halves swapped: one consumer was right and the
  other was reading noise, from the same table.

- **`Image.load_from_file` on a `res://` path works from source and ships nothing.**
  An export packs the *imported* `.ctex`, not the `.png` the importer consumed, so
  every texture in the map comes back null in an exported build — which for this game
  is the browser client, the one target that cannot be debugged by looking at it. Godot
  says so, in a warning that scrolls past with one per texture. `load()` is correct in
  both. This is Decision 8's shape again: a development path and a shipped path that
  are not the same path.

- **VTF mip levels are stored smallest-first**, so mip 0 — the full-size image — is at
  the *end* of the run. Walking forward and stopping at the first mip is the obvious
  reading and yields a 1x1 texture stretched over a wall.

- **Ignoring displacements deletes the terrain and nothing says so.** A displacement's
  face is the flat quad the mapper drew; the real surface is a grid of offsets from it.
  `Surf_Mesa` has 1434 of them, including ramps players ride, and drawing the quads
  instead produces a map that is complete, plausible and missing every rock face.

- **You cannot tell "the lightmap is unlit" from "the albedo is black" by looking**,
  and `surf_kitsune` is 5892 triangles of `tools/toolsblack`. There is no camera angle
  that separates them, because both render black through a multiply. `bsp_preview`'s
  `lm` mode overrides every material to show the baked lighting alone, which is the
  only thing that answers it. The family's "an interface is invisible to assertions",
  reached through a shader.

- **A script error inside a test aborts THAT TEST and not the run — again.** A call to
  `DotTimerZoneSet.all()`, which does not exist, removed a check while the suite
  printed **19 passed, 0 failed**. `headless_imported` asserts its own check count for
  that reason, which is the guard this tree already knew it needed.

### What importing the other six found

The importer had been run on two maps. Running it on the eight in
`godot/inspirations/g2gfast/` — and then asking whether each one could be *finished*
rather than merely loaded — found five more, and four of them were in the two maps that
had already been imported and passing.

- **A brush model's bounds are relative to the entity's `origin` key, and the importer
  ignored it.** vbsp moves a brush entity's geometry so its origin sits at (0,0,0) and
  records where that was; only worldspawn, whose origin is the world's, is the same
  either way. So **every pit volume in both imported maps was drawn piled around the
  centre of the map**, where no player goes. Nothing errored and nothing could: a
  RESPAWN volume that is never entered is indistinguishable from one nobody has fallen
  into yet, and the suite's zone section counted them and measured their thickness
  without ever asking where they were. Confirmed against the faces rather than reasoned
  about — for every trigger in `surf_kitsune` the model's own vertices span exactly the
  model's bounds, and the origin is the offset to where the mapper drew it.

- **Three of the eight maps have LZMA-compressed lumps and nothing in the header says
  so.** `bspzip -repack -compress` is what every map host runs, because a 112 MB `.bsp`
  is a 112 MB download for every player who joins; it rewrites each lump as a
  `lzma_header_t` plus a raw LZMA1 stream and leaves the file's VBSP version at 20. The
  reader read the compressed bytes as structures, got a plausible plane array out of
  them, and died in the texture string table — which is simply the first lump whose
  contents are checked against anything. `surf_aquaflow`, `surf_arcade` and
  `surf_interference` could not be imported at all, and the failure named the wrong lump.

- **A spawn yaw was never converted.** Positions crossed the axis boundary and the
  angle beside them did not. Source measures yaw about +Z from +X and `DotFpsMotor`
  builds forward as `(-sin y, 0, -cos y)`; solving the two against each other gives
  `yaw - 90`, and the manifest was writing Source's number straight through. **No number
  is wrong when this is wrong** — the player stands in exactly the right place facing
  the wrong way, which on a map with an obvious route reads as the spawn being fine.

- **A spawn 8 units above the floor is a coin toss.** `Surf_Mesa`'s spawn destination
  sits 25 units over its platform. Dropped from 10168 the player lands; from 10170 the
  player lands; from **10169**, which is where an 8-unit lift put them, the player goes
  through the floor and keeps going — and moving them one unit in x, or 320 units in y,
  fixes it. One point, on one map, and it was the point the map shipped with. A capsule
  that starts that close to a triangle seam is a coin toss whichever way the collision
  backend rounds, so the answer is not to start there: the lift is 24 units, which is
  clear of the seam and still leaves a 94.5-unit player 9 units of headroom under
  Source's own minimum 128-unit ceiling. **The `--check-only` pass and every assertion
  about the zone set passed throughout**; what found it was the one check that puts a
  player on the map and waits.

- **Two brushes sharing a targetname are ONE entity in Source, and mappers use that.**
  `surf_summit`'s `tm_checkpoint1` is a pair, one in each of the map's two mirrored
  lanes. Emitted as two zones they are two stage zones with the same number, which
  `DotTimerZoneSet.problems()` refuses — correctly — so the map went from "no timer at
  all" to "no timer, and now it says why". They are unioned back into the one volume the
  map always meant.

And one in the suite, which is worth the same: **`headless_imported` had four zone
checks and not one of them asked whether a run could be finished.** A zone set with a
start, a finish, stages numbered 1..n and no thin volumes passes every one of them and
can still be impossible to complete. `_test_runnable` drives a `DotTimer` over the map's
own zones — start, away, each stage, finish — and asserts a time comes out with every
split in it; `_test_stands_where_it_sends_you` teleports a player to each track's spawn
and each `!s<n>` destination and waits to see whether they are still there. Those two
are what say these are levels rather than geometry, and writing them found the
`Surf_Mesa` spawn above and two more artefacts of stepping a timer by hand.

### What is not imported

- **Static props.** `Surf_Mesa` carries 17 `.mdl` models in its pakfile and the
  `sprp` game lump places them. Reading MDL/VVD/VTX is a second format family and
  nothing in these two maps' *ride* depends on them — they are scenery. The geometry a
  player touches is all brushes and displacements, and that is all this reads.
- **Skyboxes, water, animated and scrolling materials.** Sky faces are skipped, so an
  imported map has the viewport's background behind it.
- **Anything from the game's own VPKs.** A `.bsp` embeds only what the mapper added:
  84% of `surf_kitsune`'s triangles and 91% of `Surf_Mesa`'s. The rest — CS:S stock
  textures like `concrete/concretefloor039a`, which is the ramp — are painted with the
  [G2GTextures] role colour instead, which is what an untextured surface means here.

**These maps are third-party work.** `godot/inspirations/` is read-only reference in
the shape `external-study/` already has: reading a map for its dimensions, its ramp
angles and its stage layout is the point of having it. Shipping extracted geometry in a
released game is a different act and needs the author's permission.

### Maps are dropped in, not listed

There is no list of maps in this repository. `G2GMapCatalogue` scans, and a map is
whatever has a scene and a sidecar, or is just a manifest:

```
maps/<id>.tscn   + maps/<id>.zones.json    hand-written: a scene and a script
<root>/<id>/<id>.json                      imported: data, and nothing else
```

**An imported map has no scene and no script, and that is what makes it droppable.**
Every one of them is `maps/imported_map.tscn` — one scene, inside the build — pointed
at a different manifest through `DotMapDef.meta`. The obvious alternative, a generated
`<id>.gd` and `<id>.tscn` beside the data, was what this shipped first and it cannot
work for a map that arrives *after* the export: `res://` is a read-only PCK in a built
game, so a scene that is not in it does not exist. A script in a delivered dot-cloud
pack could not resolve `extends G2GBspMap` either — this family measured that and wrote
it down — so the same change fixes both.

The roots searched are `res://maps/imported` (baked into an export), `user://maps`
(where anything downloaded at runtime lands, and **the only way a shipped server can be
given a new map**), and whatever `g2g_maps_directory` names. First root wins, so a map
in the build is not silently replaced by one dropped in beside it.

```bash
cp somewhere/surf_whatever.bsp ../inspirations/g2gfast/
tools/import_maps.sh            # imports what is new, skips what is current
tools/import_maps.sh --prune    # and deletes imports whose .bsp is gone
tools/bsp_preview.sh            # and renders every one of them from its spawn
```

If the import prints `NO START` or `NO END` for the main track, the map labels neither
and needs a `maps/zones/<id>.json`. It is still offered — a map you can walk around is
worth having — but nothing will time a run on it.

and on a running server, `g2g_maps_reload` rescans without a restart.

**The rescan mutates the catalogue in place rather than replacing it.**
[DotMapRotation] holds the catalogue by reference and reads its pool live, so swapping
the object leaves the rotation offering exactly the maps that are no longer there.

**The map being played is deliberately not unloaded when it disappears from disk.** Its
scene is resident, the players on it are mid-run, and taking the world out from under
them to enforce a directory listing is worse than letting it finish and never be chosen
again. `g2g_maps_reload` says so in its reply.

This replaced **three** hardcoded copies of the same three map ids —
`G2GGame._map_catalogue`, `tools/export_zones.gd`, and the ad-hoc lists in the export
scripts. That is this tree's most repeated bug and it had reached this repository too.

**Verified by dropping one in**: a map copied into `user://maps/`, never in the build,
with no script, no scene and no `.import` files, loads and plays and renders
identically to the same map under `res://`.

### What making it dynamic found

- **A client could not be configured at all.** `G2GClient` built a bare `G2GConfig` and
  never called `load_layered()`, so the family's `defaults < JSON < env < argv` chain —
  which this file's Decision 1 is about — ran on the server, in every suite, and nowhere
  on the client. `--g2g-initial-map surf_kitsune` reached a dedicated server and went
  nowhere offline, which always played whatever the export defaulted to. It is the
  family's own convention missing from exactly one file, and no test could see it
  because every suite sets `config.initial_map` directly, which is the path that works.

- **Every imported pit volume was thin enough to fall through.** Source *sweeps* its
  trigger tests; `DotTimerZoneIndex` asks `contains(point)` once a tick. A mapper draws
  a `trigger_teleport` as a 16-unit plane because in Source that is enough — and at
  3500 u/s and 128 Hz a player travels 27 units between samples, so a falling surfer
  steps clean over the pit and falls for ever. **48 of surf_kitsune's 53 respawn volumes
  and 7 of Surf_Mesa's 10** were that thin. The importer now inflates a thin volume into
  a slab centred on the original plane — centred, because downward is right for a pit
  and wrong for a boundary trigger above the play space, and a centred slab is the
  honest approximation of the swept test Source was doing.

  This is the same failure this file already records twice: *the thing dot-timer's
  RESPAWN zones exist to prevent was the thing that did not happen*, and it announced
  itself as one warning line during an ordinary run. `headless_imported` now asserts
  `thin_zones()` is empty, which is the check `headless_run` has always made for the
  hand-written maps and nobody had extended to the imported ones.

## The detector, turned on this game's own new code

The family's rule is that **an exported setting whose name occurs exactly once in its
repository is a setting nothing reads**. The same grep over *methods* is worth as much
and had never been run: a public method whose name occurs once is a method nothing
calls. Turned on the twenty-six-addon pass it found seven, and the first is the one
that matters:

- **`G2GCombat.set_fire_command`, which meant `sv_deathmatch` was a mode nobody could
  shoot in.** The arsenals were built, the hitboxes were registered, the match was
  counting, and the fire command every tick read was one nothing ever set. The fix is a
  bit on `G2GNetCommand` rather than a request, and the reason is prediction: a shot
  happens on a tick and has to be replayed with the movement of that tick, so a trigger
  arriving reliably-and-separately would be replayed against a different tick's
  position every time. It is applied in `_net_apply_input`, which is the one place that
  runs on a replay as well as on a fresh tick — and **not retained across a lost
  packet**, unlike the movement: a held trigger that survives a hiccup is a weapon that
  empties itself during one.
- **`G2GArsenal.weapon_table`, which meant `DotLoadoutManager` was a manager of
  nothing.** It was built, given a schema and a store, and asked for nothing; everybody
  got a hard-coded knife and deagle. dot-loadout has never heard of a `DotWeapon` and
  dot-combat has never heard of a `DotItem`, and the table between them is the whole
  join.
- **`G2GClientExtras.receive_line`.** The client's `DotChatClient` was a history nothing
  fed. `G2GServices` routes a line through dot-chat and hands it to dot-server's manager
  to put on the wire, so on the client it arrives on `DotClientLink.chat_received` — not
  on anything dot-chat owns.
- **`G2GIdentity.avatar_for`.** dot-platform's module runs off `client_state_changed`
  because dot-server has no cancellable stage between authentication and content, so a
  player can be in the world with the platform still resolving them. The module's own
  `_avatar_for` now falls through to the hub, which falls through to the stock document.
- **`G2GProps.phys_gun`, `G2GHunters.spawn_one`, `G2GStats.finish_rate_of`** — a tool,
  an admin spawn and a derived figure, each reachable from nothing. `g2g_nudge`,
  `g2g_hunt spawn` and `!stats` are the doors.

Two things the new checks found that were not on the list:

- **A grab is once and a held prop moves every tick.** A layer that only called `grab`
  gives an admin a block that stays exactly where it was picked up, which reads as the
  physics gun not working rather than as a missing `hold`.
- **A GDScript lambda captures locals by value.** The shot counter was an `int`
  incremented inside a signal handler, so it stayed zero outside it — and the assertion
  reported a failure for a signal that had fired perfectly. This file's own family notes
  carry that warning, and the check was written wrong anyway.

## The characters are Kenney's, scaled to the genre's hull

`avatars/{body,head}_kenney_<a..r>.tscn` are 18 characters from Kenney's Blocky
Characters (CC0), generated by `tools/build_avatar_parts.gd` out of `avatars/kenney/`.
The two primitives that came first stay at the FRONT of `BODIES` and `HEADS`: `[0]` is
the schema's default, so a deployment without the art directory still resolves a default
part and an avatar document written before the art arrived still loads. A capsule is a
worse character and a better fallback.

**The scale is the whole job, and this game is the awkward one.** A Kenney character is
2.70 m; this game's player is 72 genre units, which is **1.372 m** — so an imported
character is very nearly TWICE the size of the thing it represents, standing with its
head above the camera, with every property of every node correct. The generator measures
the kit and derives the factor (0.508 here) rather than carrying a constant, because
game-arena runs the same kit against a 1.8 m capsule and gets 0.667: one number, written
down twice, would be this file's most repeated bug in a new place.

`G2GRig` mounts the body at 42% of the hull and the stock capsule is centred there, which
floats it about 13 cm — invisible on a capsule and a character standing in mid-air the
moment the part has legs. The body is foot-aligned; the head stays centred. **The rig is
not changed for this**, because arena mounts the same way and its parts are still
primitives: the art fits the rig.

`tools/avatar_preview.tscn` draws the parts inside a wireframe of the hull they have to
fit. Every one of those three was found by looking at a frame — "is this the right size"
is not a question an eyeball on a character alone can answer, and it is the same lesson
as the 0 x 0 `Control`s.

## Spectating, and effects with a rule

### `!spec`, which this game shipped without

**On a timer server, spectating is the point rather than a consolation for being dead.**
A record is set by one person, once, and everybody else on the server wants to watch it
being set — `!spec ada` is a command bhop and surf servers have had for fifteen years.

Two settings follow from that and both are the opposite of an arena's:

- **`force_camera` is 0.** There are no sides on a timer server, so restricting the
  camera to "your own team" restricts it to everybody and means nothing. It tightens to
  1 the moment `sv_deathmatch` is on, where a living player watching a living one is a
  free wallhack.
- **`allow_while_alive` is on.** Somebody standing in the start zone deciding whether to
  run is not dead, and refusing them the camera is a rule from a game this is not.

`!spec` with no argument watches whoever is **furthest into a run** — furthest rather
than fastest, because "who is nearly finished" is the question a spectator is asking and
somebody two seconds into a personal best is not the answer. The camera is driven once a
**frame**, for the reason `jitter_probe.tscn` exists.

### A movement effect is a style, and a style you did not choose is a record you did not set

This is the whole design of `G2GEffects` and the reason it is not four lines.

Everything in this game exists to make a run comparable with one somebody else set, on
another server, at another tick rate: sub-tick zone crossings, a rate taken from
`sv_tickrate` rather than an export, styles paired between dot-fps-controller and
dot-timer by id. **An effect that quietly multiplies `max_speed` by 0.65 undoes all of
it**, and the player has no way of knowing it happened.

So effects here are split, and the split is enforced rather than documented:

| | |
| --- | --- |
| **Combat effects** — a bleed, a burn | Anybody, any time. They cannot change a time. |
| **Movement effects** — a maul, a haste | **Refused** while a ranked run is live. |

`G2GEffects.is_movement()` asks the *definition* whether it changes `move_speed_scale` or
`jump_scale`, rather than consulting a list of ids — so an effect added later is
classified by what it does rather than by somebody remembering to name it.

A server that wants hunted runs to count anyway sets `allow_movement_during_runs`, and
every such run is **tainted**. `DotTimerRun.tainted` has existed since dot-timer was
written and this is its first caller; it is what keeps a hunted run off a board beside a
clean one, which is the honest version of allowing it.

That is also what makes the hunters interesting rather than annoying: being chased has to
cost you something, and the thing it costs you is the record.

### Two id spaces meet at `entity_for`

This game keys players by `StringName`; dot-combat and dot-effects both key by `int`.
`G2GCombat.entity_for` is the direction that was missing — `player_id_for` had existed
since the class was written and nothing went the other way. A caller that hashed the name
instead would get a number that is stable, plausible, and **not** the one the health, the
hitboxes and the kill feed use.

## `!spec` did nothing, and `g2g_map` deliberately still does

Two halves of the same gate, and they point opposite ways.

`G2GServices` hooks `player_command` as well as `player_chat`. Without it,
`DotChatRouter.command_entered` **could not fire**: dot-server's chat manager checks for
a command prefix before it fires `player_chat`, `_handle_command` returns on every path
including the unknown one, and its prefixes are `["!", "/"]` — identical to
`DotChatRules`'. So no `!` line ever reached the router.

`!rtv` survived that because `rtv` is also a console alias registered `.with_chat()`.
**`!spec` and `!spectate` are handled nowhere else and did nothing at all** — and the
module's own `_` branch said "left for dot-server's own chat commands", which was true
for `!r`, `!wr` and `!top` and quietly false for the two this game added later.

**`g2g_map` is console-only on purpose and `examples/dedicated.gd` asserts it** —
`not map_command.chat_allowed`, in so many words. It is the only command in its block
without `.with_chat()`, which reads exactly like an oversight and is not: a map change
destroys every run in progress, so a records server does not let a player do that by
typing. It goes through the console, RCON, or the vote.

That assertion earned its keep: it caught the flag being added and the suite went to
120/1 on the spot. **A missing flag its neighbours have is evidence of nothing until you
have checked whether a suite asserts the difference.** A command relayed from the website
arrives as `Source.CHAT` and is refused here too; `DotChatRelayConfig.command_source` is
the switch for an operator who wants their site admins to reach it.

## Things deliberately not here

- **A second transport.** The bridge speaks through `DotClientLink`'s RPCs on one
  `MultiplayerAPI`; browser and desktop clients on one server is the family-wide gap
  in PLATFORM.md.
- **A sandbox.** There are practice blocks now (`sv_props`), and they are deliberately
  not a sandbox: frozen on placement, admin-only by default, and a run made while
  anything is placed cannot be ranked. game-playground is the sandbox.
- **A chat window.** `DotChatClient` holds the history, the channels and the unread
  counts on the client the moment anybody writes a screen for it; what a player gets
  today is the HUD's notice line.
- **A server browser SCREEN.** The browser itself is wired in and asks a real
  `DotServer`; what it draws is a chat listing, and a table a player can click a row
  of is a `DotScreen` and a stack this client does not have.
- **A master server.** `DotBrowserSourceBackbone` reads a listing that nothing is yet
  publishing, and there is no heartbeat — so a browser here finds what somebody typed
  into it and nothing else. That gap is the family's, not this game's.
- **A map-sync client.** game-arena has one; this game does not need one, because
  `G2GGame` drives a `DotMapSession` on every instance including a mirroring client
  and the bridge already sends a map change as a game event. Adding `DotMapSyncClient`
  on top would be a second thing loading the same map, which is two owners of one
  world.
- **A texture set.** `G2GTextures` generates a prototype grid and looks for an
  installed one in `res://textures/prototype/{floor,ramp,start,end,platform,bonus}.png`.
  Dropping files in changes every map in the game with no code change, because
  `G2GGeometry.box` takes a ROLE rather than a colour and the roles are the whole
  interface.

  **Kenney's prototype kit was tried here and is not it.** It was installed, rendered
  and compared against the generated grid, and it is a downgrade — so the entry that
  used to say it "is what those files are for" was optimistic and this is what was
  measured instead. Two reasons, and both are about the pipeline rather than the art:

  - **The tint is a MULTIPLY**, so the source has to be light. Kenney's *Dark* set is a
    dark base with light lines, and a dark base multiplied by a role colour is very
    nearly black.
  - **The *Light* set is too low-contrast at this tiling.** The generated grid draws a
    darker line every square and a lighter one every `SQUARES_PER_TILE`, which is what
    makes a floor something you can judge distance and speed against at 3000 u/s. A
    1024x1024 Kenney panel stretched over the same area reads as almost flat, and a
    movement game whose floor has no readable scale is harder to play, not prettier.

  What would work is a light, high-contrast set whose line weight survives the tiling —
  the generated grid is the specification for that, not a placeholder to be replaced by
  the first CC0 kit to hand.
