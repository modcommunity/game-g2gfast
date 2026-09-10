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
  imported/<id>/    what tools/bsp_import.py wrote: <id>.bin, <id>.json, the
                    lightmap atlas, the textures the .bsp carried, and the four-line
                    <id>.gd and <id>.tscn. All derived; gitignored; never hand-edited
avatars/            six stock parts and the tint shader
scenes/
  g2g_server.tscn   what a dot-server loads. A G2GGame under a plain Node
examples/           headless_run (93), headless_net (85), dedicated (52),
                    headless_imported (20 per imported map)
tools/              export_zones.gd — run after changing a map
                    bsp_read.py, vtf.py, bsp_import.py — Source .bsp to a map
                    bsp_preview.gd/.tscn — render an imported map and exit
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

Three of them now: `bhop_g2g_intro`, `surf_g2g_intro` and `bhop_g2g_stages`.

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
godot --headless --path . res://examples/headless_run.tscn   # 110 checks
godot --headless --path . res://examples/headless_net.tscn   # 90 checks
godot --headless --path . res://examples/dedicated.tscn      # 107 checks
godot --headless --path . res://examples/jitter_probe.tscn   # 4 configurations
godot --headless --path . res://examples/headless_imported.tscn  # 20 per imported map
```

`headless_imported` skips cleanly when `maps/imported/` is empty, because an imported
map is optional content and a fresh clone that has never run the importer is not
broken. It iterates whatever is there rather than naming a map, for the reason the
catalogue does.

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
compiler baked, and the volumes that catch a player who fell off the ride. It was
written against `surf_kitsune` and `Surf_Mesa` in `godot/inspirations/`.

**The scale is not converted, because there is nothing to convert.** Source stores map
coordinates at 0.75 inch per unit and [G2GUnits] already declares exactly that ratio,
for exactly this reason — a surf ramp imported at the 1-inch figure is a ramp the
movement cannot hold. A BSP coordinate *is* a genre unit. The whole transform is the
axis swap, because Source is Z-up and Godot is Y-up:

    godot = (src.x, src.z, -src.y)

**START and END zones are deliberately not guessed.** A `.bsp` is compiled: the brush
entity that knew "this is the start platform" is gone, and CS:S has no convention that
survives. `surf_kitsune` drives its stages with
`OnTrigger !activator,AddOutput,targetname X` and a filter chain, which is a program
and not a label. What IS reliable is `trigger_teleport` — the pit — and that maps
exactly onto `DotTimerZone.Kind.RESPAWN`. An imported map arrives playable and
untimed; the timing zones are a hand-written pass, which is the honest division.

**The mesh is a binary and not a glTF, and the reason is one array.** The baked
lighting needs `ARRAY_TEX_UV2` to reach the shader, and every route through an
importer decides for you what a second UV set means: glTF's occlusion channel is
greyscale, so the coloured neon that is `surf_kitsune`'s entire character goes grey,
and its emissive channel is additive, so it washes out. Building the [ArrayMesh] from a
`PackedByteArray` costs one pass and keeps this repository's own convention anyway —
maps here are made in code.

**Imported maps are discovered, not listed.** `G2GGame._add_imported_maps` scans
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
  Kenney's prototype kit is CC0 and is what those files are for; dropping them in
  changes every map in the game with no code change, because `G2GGeometry.box` takes a
  ROLE rather than a colour and the roles are the whole interface.
