class_name G2GGame
extends Node3D

## g2gfast: the simulation. Maps, timers, styles, records, and every player.
##
## [b]A bunny-hop and surf server in the competitive-shooter shape[/b]: the genre's
## movement cvars in the genre's units, a timer with zones an admin draws from the console, styles,
## a records table, and a rotation. Runs headless as a dedicated server and is what a
## client draws.
##
## [codeblock]
## godot --headless --path . res://examples/headless_run.tscn
## godot --headless --path . res://examples/dedicated.tscn
## [/codeblock]
##
## [b]What is this game's own, versus the addons'.[/b] Every rule about movement lives
## in dot-fps-controller, every rule about timing in dot-timer, maps in dot-map,
## records in dot-leaderboard. What this file adds is the joins — the tick order, the
## unit boundary, the moment a cvar change reaches thirty players — and the joins are
## where every bug in this family has been.

const CHANNEL := "g2g"

## The registry name a dot-server module finds this under.
const SERVICE := &"g2g_game"

## The ghost's player id. Session ids are dot-server userids, which never get
## this large; the bridge treats it as a session like any other.
const GHOST_ID := &"u900000001"
const GHOST_SESSION := 900000001

signal map_ready(map: DotMapDef)

## The map catalogue was re-read from the disk. Carries `added`, `removed`, `total`.
signal maps_rescanned(change: Dictionary)
signal run_filed(player_id: StringName, run: DotTimerRun, rank: int, reason: String)

## The movement changed under everybody — a cvar, or a config reload.
signal movement_changed(config: G2GConfig)

## A player the game created itself — a ghost — or one a caller added. A netcode
## bridge adopts the former as a bot.
signal player_added(player: G2GPlayer)
signal player_removed(player_id: StringName)

@export var config: G2GConfig = null

## A JSON file layered over [member config]'s defaults, or empty.
@export var config_file: String = ""

## Fallback tick rate when nothing has told the engine. A dot-server always has.
@export_range(1, 240, 1) var tick_rate: int = 128

## Registry scope, so a server game and a client game can share one process — the
## shape every headless netcode test in this family takes.
@export var service_scope: StringName = &""

var authoritative: bool = true

var maps: DotMapSession = null
var timers: DotTimerManager = null
var boards: DotLeaderboardManager = null
var world: Node3D = null

## The tunables every player is on, before their style. Rebuilt on a cvar change.
var tunables: DotFpsTunables = null

## Movement halves of the styles, by id. The ranking halves are on the timer manager.
var movement_styles: Dictionary = {}

## The avatar schema and catalogue every rig is dressed from.
var avatar_schema: DotAvatarSchema = null
var avatar_catalogue: DotAvatarCatalogue = null

var players: Dictionary = {}

## The best replay per map, track and style. What the ghost plays.
var replays: G2GReplays = G2GReplays.new()

## The deathmatch half. Null unless `sv_deathmatch` built it.
##
## [b]A layer, not a mode switch on the game.[/b] While it exists the timer still runs
## and a player who never presses fire plays exactly the game they played before —
## which is the only shape a deathmatch on a records server can honestly take.
var combat: G2GCombat = null

## Hunters on the course. Null unless `sv_hunters` built them.
var hunters: G2GHunters = null

## Props an admin can place. Null unless `sv_props` built them.
var props: G2GProps = null

## Statistics and achievements. Null on a client, and on a server that keeps none.
##
## [b]Authority only.[/b] A mirroring client sees every finish replicated to it, and
## counting them there would file everybody's runs a second time in a place the server
## never reads — and let a modified client award itself achievements. The numbers
## belong to whoever decides whether a run counted.
var progress: G2GProgress = null

var _samples: Dictionary = {}
var _tick: int = 0
var _accumulator: float = 0.0

## Whether something else drives the tick — a net bridge, whose tick has to happen
## between dot-net applying inputs and building the snapshot. See [G2GNetBridge].
var external_tick: bool = false


func _ready() -> void:
	if config == null:
		config = G2GConfig.new()

	var loaded := config.load_layered(config_file)

	if not loaded.ok:
		DotLog.error(CHANNEL, "the g2gfast configuration is not usable", {
			"why": loaded.error.message
		})

	authoritative = config.authoritative
	tick_rate = _resolve_tick_rate()
	# Snapped to float32 before anything derives from it: that is the precision
	# the wire carries, and a server has to move its players with the values its
	# clients were sent. See [method G2GConfig.snap_movement].
	config.snap_movement()
	tunables = G2GMovement.tunables_for(config)

	DotRegistry.register(DotRegistry.scoped_name(SERVICE, service_scope), self)

	DotLog.info(CHANNEL, "g2gfast starting", {
		"config": config.describe_summary(),
		"tick_rate": tick_rate,
		"authoritative": authoritative,
	})

	world = Node3D.new()
	world.name = "World"
	add_child(world)

	avatar_schema = G2GAvatars.schema()
	avatar_catalogue = G2GAvatars.catalogue()

	_build_styles()
	_build_boards()
	_build_timers()
	_build_progress()
	_build_layers()
	_build_maps()

	set_physics_process(true)

	if config.initial_map != &"":
		var started: DotResult = await change_map(config.initial_map)
		DotLog.result(CHANNEL, "loading the first map", started)


## The engine's rate when a server has set it, else the export. See game-playground.
func _resolve_tick_rate() -> int:
	return Engine.physics_ticks_per_second if Engine.physics_ticks_per_second > 0 else tick_rate


## Counts at [param rate] ticks a second from now on. Returns whether it changed.
##
## [b]A client's rate is the SERVER's, and it does not come from the engine.[/b]
## `_resolve_tick_rate` reads `Engine.physics_ticks_per_second`, which on a server is
## `sv_tickrate` and on a client is whatever the host project exported — 128 here, 60
## in a project that never set it. So a client left on its own number simulates at a
## rate the server does not, and since `1.0 / tick_rate` is the step prediction
## replays with and the divisor every replicated run time is reconstituted through, a
## client on 60 against a server on 128 shows times wrong by that ratio while
## everything else looks healthy. [G2GNetBridge] calls this from HELLO, which has
## carried the server's rate since it was written.
##
## Every run in progress is abandoned, by [method DotTimerManager.set_tick_rate]'s own
## rule: a run half at one rate and half at another is a run at neither. That costs
## nothing here, because this is called before a client has a player.
func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	timers.set_tick_rate(rate)
	# Read back rather than assigned: the timer manager clamps, and two copies of
	# this number that disagree is the failure the whole method exists to prevent.
	tick_rate = timers.tick_rate

	for id in players:
		(players[id] as G2GPlayer).tick_rate = tick_rate

	DotLog.info(CHANNEL, "tick rate adopted", {"tick_rate": tick_rate})
	return true


# --- Building --------------------------------------------------------------

func _build_styles() -> void:
	for style in DotFpsStyle.defaults():
		# Prespeed limits are in genre units here, like everything a style says to
		# an operator. 290 u/s is the number every CS:S timer ships.
		style.prespeed_limit = 290.0

		# [b]The SERVER decides auto-hop, not the style.[/b] The shipped styles force
		# it on, which is right for a game with no cvar and wrong here: with the
		# style overriding the base, `sv_autobunnyhopping 0` reached every player's
		# tunables and was then undone by the style on top — silently, and the
		# integration suite caught it as a held key still hopping. Every style
		# inherits, except the one whose whole identity is "no auto-hop".
		if style.id != &"prebhop":
			style.auto_hop = DotFpsStyle.Toggle.INHERIT
			style.easy_bhop = DotFpsStyle.Toggle.INHERIT

		movement_styles[style.id] = style


func _build_boards() -> void:
	boards = DotLeaderboardManager.new()
	boards.name = "Leaderboards"
	boards.store = DotLeaderboardStoreMemory.new()
	boards.report_to_backbone = config.report_to_backbone
	add_child(boards)

	var fastest := DotLeaderboardDef.make(&"fastest", DotLeaderboardDef.Kind.TIME)
	fastest.display_name = "Fastest time"
	boards.define(fastest)

	var points := DotLeaderboardDef.make(&"points", DotLeaderboardDef.Kind.POINTS)
	points.display_name = "Ranking points"
	points.decimals = 1
	boards.define(points)


func _build_timers() -> void:
	timers = DotTimerManager.new()
	timers.name = "Timers"

	var timer_config := DotTimerConfig.new()
	timer_config.tick_rate = 0
	timer_config.default_tick_rate = tick_rate
	timer_config.authoritative = authoritative
	timer_config.record_runs = true
	timer_config.records_directory = config.records_directory
	timer_config.record_replays = config.record_replays
	timer_config.fastest_expected_speed = G2GUnits.to_metres(config.max_velocity)
	timers.config = timer_config

	add_child(timers)
	tick_rate = timers.tick_rate

	var timer_styles := DotTimerStyle.defaults()
	for style in timer_styles:
		# The community timers' `startinair`, on: a bunny-hopper leaves the start pad mid-hop far
		# more often than not, and a run that only begins from a grounded exit is
		# one most players never start. The prespeed clamp is what stops the "build
		# speed outside and dive through" trick this switch was for.
		style.allow_air_start = true
	timers.set_styles(timer_styles)

	var replays_ready := replays.setup(config.records_directory if config.record_replays else "")
	if not replays_ready.ok:
		DotLog.warn(CHANNEL, "replays will not persist", {"why": replays_ready.error.message})
	timers.record_accepted.connect(_on_record_accepted)
	timers.record_refused.connect(_on_record_refused)
	timers.effect_requested.connect(_on_effect_requested)
	timers.player_finished.connect(_on_player_finished)


## Statistics and achievements, if this instance keeps any.
##
## [b]After the timers and before the maps, and both halves of that matter.[/b]
## [method G2GProgress.attach] connects to the timer manager's own signals, which do
## not exist until `_build_timers` has run; and it connects to `map_ready`, which
## `_build_maps` can fire during `_ready` when an initial map is configured — so a
## progress node built afterwards would miss the first map of the session.
func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = G2GProgress.new()
	progress.name = "Progress"
	progress.report_to_backbone = config.report_to_backbone
	progress.progress_dir = config.records_directory
	add_child(progress)

	var attached := progress.attach(self)

	if not attached.ok:
		# A server with no statistics is a server. One that refuses to boot because an
		# achievement catalogue was rejected is not.
		DotLog.warn(CHANNEL, "progression is off", {"why": attached.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null


## The deathmatch, the hunters and the props, if this server runs any.
##
## [b]Before `_build_maps`, and that is load-bearing.[/b] All three connect to
## `map_ready`, and `_build_maps` can fire it during `_ready` when an initial map is
## configured — so a layer built afterwards misses the first map of the session, which
## for the hunters means no route and for the props means nothing cleared.
##
## [b]Each one is built whether or not it is enabled.[/b] `enabled` is a live cvar an
## operator flips mid-map, and a layer that only existed when it was on would have to
## be constructed under live players — which is where the interesting failures are.
## Built and off costs a node and three signal connections.
func _build_layers() -> void:
	if not authoritative:
		return

	if config.deathmatch or config.hunters:
		# The hunters need somewhere to put damage, so combat is built for either.
		# A hunter that could hurt a player the server is not tracking would be doing
		# damage nothing could heal, display or respawn away.
		combat = G2GCombat.new()
		combat.name = "Combat"
		combat.game = self
		combat.enabled = config.deathmatch
		add_child(combat)

		var armed := combat.setup()

		if not armed.ok:
			DotLog.warn(CHANNEL, "deathmatch is off", {"why": armed.error.message})
			remove_child(combat)
			combat.queue_free()
			combat = null

	if config.hunters:
		hunters = G2GHunters.new()
		hunters.name = "Hunters"
		hunters.game = self
		hunters.enabled = true
		add_child(hunters)

		var hunting := hunters.setup()

		if not hunting.ok:
			DotLog.warn(CHANNEL, "the hunt is off", {"why": hunting.error.message})
			remove_child(hunters)
			hunters.queue_free()
			hunters = null

	if config.placeable_props:
		props = G2GProps.new()
		props.name = "Props"
		props.game = self
		add_child(props)

		var placed := props.setup()

		if not placed.ok:
			DotLog.warn(CHANNEL, "props are off", {"why": placed.error.message})
			remove_child(props)
			props.queue_free()
			props = null


func _build_maps() -> void:
	maps = DotMapSession.new()
	maps.name = "Maps"
	maps.world_ref = DotNodeRef.of_path(^"../World")
	add_child(maps)

	maps.catalogue = _map_catalogue()

	if config.catalogue_path != "":
		DotLog.result(CHANNEL, "loading the map catalogue",
			maps.load_catalogue(config.catalogue_path))

	maps.rotation = DotMapRotation.of(maps.catalogue)
	maps.rotation.cooldown = 1
	maps.time_limit.duration = config.map_seconds

	maps.changing.connect(_on_map_changing)
	maps.changed.connect(_on_map_changed)
	maps.map_over.connect(_on_map_over)


## Every map on disk. See [G2GMapCatalogue] — there is no list here on purpose.
func _map_catalogue() -> DotMapCatalogue:
	return G2GMapCatalogue.discover(_map_roots())


## Extra places to look for imported maps, from the configuration.
func _map_roots() -> PackedStringArray:
	var out := PackedStringArray()
	if config != null and not config.maps_directory.is_empty():
		out.append(config.maps_directory)
	return out


## Pick up maps added to or removed from the disk since this server booted.
##
## [b]Why a server needs this at all:[/b] the point of an imported map is that an
## operator drops one in, and a game that only reads the disk once makes them restart
## to play it — which on a live server means kicking everybody to add a map.
##
## The map being played is deliberately NOT unloaded when it disappears from the disk.
## Its scene is already resident, the players on it are mid-run, and taking the world
## out from under them to enforce a directory listing is a worse outcome than letting
## the current map finish and never being chosen again.
func rescan_maps() -> Dictionary:
	if maps == null or maps.catalogue == null:
		return {"added": [], "removed": [], "total": 0}

	var playing: StringName = maps.current.id if maps.current != null else &""
	var change := G2GMapCatalogue.rescan(maps.catalogue, _map_roots())

	if playing != &"" and not maps.catalogue.has(playing):
		DotLog.warn(CHANNEL, "the map being played is no longer on disk",
			{"map": String(playing)})

	DotLog.info(CHANNEL, "map catalogue rescanned", {
		"added": change["added"].size(),
		"removed": change["removed"].size(),
		"total": change["total"],
	})
	maps_rescanned.emit(change)
	return change


# --- Movement cvars --------------------------------------------------------

## Rebuilds the movement from [member config] and hands it to every player.
##
## [b]What `sv_autobunnyhopping 1` does, and every run in progress is abandoned by
## it.[/b] The tunables are an input to the simulation, so a run that was half on one
## set and half on another is not comparable with anything — the same reason a tick
## rate change abandons runs. It costs everybody one attempt, and a server changing
## its movement is a server whose operator is asking for exactly that.
func apply_movement() -> void:
	config.snap_movement()
	tunables = G2GMovement.tunables_for(config)

	for id in players:
		var player: G2GPlayer = players[id]

		if player.timer != null:
			player.timer.stop(DotTimer.REASON_RESET)

		var applied := player.set_movement(tunables)

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not take the new movement", {
				"player": String(id), "why": applied.error.message
			})

	DotLog.info(CHANNEL, "movement applied", {
		"autobhop": config.auto_bhop,
		"airaccel": config.air_accelerate,
		"gravity": config.gravity,
		"fingerprint": tunables.fingerprint(),
	})

	movement_changed.emit(config)


# --- Players ---------------------------------------------------------------

func add_player(
	id: StringName, display_name: String, local: bool = false, avatar: DotAvatar = null
) -> G2GPlayer:
	if players.has(id):
		return players[id]

	var player := G2GPlayer.new()
	player.name = "Player_" + String(id)
	player.player_id = id
	player.display_name = display_name
	player.tick_rate = tick_rate
	player.samples_input = local
	player.has_camera = local
	player.base_tunables = tunables
	add_child(player)

	var added := timers.add_player(id, display_name)
	if not added.ok:
		DotLog.warn(CHANNEL, "could not give a player a timer", {
			"player": String(id), "why": added.error.message
		})

	player.timer = timers.timer_for(id)
	player.set_style(movement_styles[&"normal"], timers.style_for(&"normal"))

	if player.camera != null:
		player.camera.fov_desired = config.fov_desired
		player.camera.allow_third_person = config.allow_thirdperson
		player.camera.set_mode(
			G2GCamera.Mode.THIRD_PERSON if config.default_thirdperson and config.allow_thirdperson
			else G2GCamera.Mode.FIRST_PERSON
		)

	# Their own avatar when they have one, a stock character when they do not. The
	# stock one is a real document over the same schema, so nothing about drawing
	# changes the day the platform hands one over.
	var dressed := player.rig.dress(
		avatar if avatar != null else G2GAvatars.stock_avatar(id),
		avatar_schema, avatar_catalogue
	)
	if not dressed.ok:
		DotLog.warn(CHANNEL, "a player could not be dressed", {
			"player": String(id), "why": dressed.error.message
		})

	players[id] = player
	_samples[id] = DotTimerSample.new()

	if progress != null:
		# Not awaited: an achievement store may be remote and a join may not wait on
		# it. Readings that arrive during the load are still counted — see
		# `G2GProgress.begin`.
		progress.begin(id, display_name)

	spawn_player(id)
	player_added.emit(player)

	return player


## Puts the record's replay on the map as a player everybody sees.
##
## A ghost is a [G2GPlayer] with [member G2GPlayer.replay] set, so it replicates
## through the same bridge as a person: the server drives it, clients interpolate
## it, and a browser client that could not decode a replay still sees the run.
func spawn_ghost(track: int = DotTimerTrack.MAIN, style_id: StringName = &"normal") -> G2GPlayer:
	if not authoritative or not config.show_replay_bot or maps.current == null:
		return null

	var best := replays.best(maps.current.id, track, style_id)
	if best == null:
		return null

	remove_player(GHOST_ID)

	var player := add_player(
		GHOST_ID, "WR %s · %s" % [DotTimerRun.format_time(best.time), best.player_name], false
	)
	if player == null:
		return null

	var replay_player := DotTimerReplayPlayer.new()
	var loaded := replay_player.load_replay(best)
	if not loaded.ok:
		remove_player(GHOST_ID)
		return null

	timers.remove_player(GHOST_ID)
	player.timer = null
	player.replay = replay_player
	replay_player.play()
	return player


func ghost() -> G2GPlayer:
	return players.get(GHOST_ID)


func remove_player(id: StringName) -> void:
	if not players.has(id):
		return

	maps.time_limit.unrock(id)
	timers.remove_player(id)
	(players[id] as G2GPlayer).queue_free()
	players.erase(id)
	_samples.erase(id)
	player_removed.emit(id)


func spawn_player(id: StringName) -> void:
	var player: G2GPlayer = players.get(id)
	if player == null:
		return

	var track := player.timer.track if player.timer != null else DotTimerTrack.MAIN
	var map := current_map_node()

	if map != null:
		player.teleport(map.spawn_for(track), map.spawn_yaw_for(track))
	else:
		player.teleport(Vector3(0.0, 2.0, 0.0), 0.0)


func set_player_style(id: StringName, style_id: StringName) -> bool:
	var player: G2GPlayer = players.get(id)
	if player == null or not movement_styles.has(style_id):
		return false

	var ranking := timers.style_for(style_id)
	if ranking == null:
		return false

	return player.set_style(movement_styles[style_id], ranking).ok


func current_map_node() -> G2GMap:
	return maps.world as G2GMap if maps != null else null


# --- The tick --------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if external_tick:
		return

	var step := 1.0 / float(maxi(tick_rate, 1))
	_accumulator += delta
	var budget := 8

	while _accumulator >= step and budget > 0:
		_accumulator -= step
		budget -= 1
		_tick += 1
		_simulate_tick(step)

	if _accumulator >= step:
		_accumulator = 0.0


## The tick this game is on.
##
## Read rather than reconstructed. `_tick` is advanced by three different callers —
## the accumulator in `_physics_process`, `tick_once` from a netcode bridge, and
## `tick_timers_only` on a client — and anything deriving its own would be a fourth
## copy of a number that already exists.
func current_tick() -> int:
	return _tick


## One authoritative tick driven from outside, at a tick number the driver chose.
func tick_once(tick: int) -> void:
	_tick = tick
	_simulate_tick(1.0 / float(maxi(tick_rate, 1)))


## Feeds every timer from the players' current positions without moving anybody.
##
## The client's tick: prediction moved the local player through its behaviour and
## snapshots moved everybody else, so the only thing left to do per tick is what the
## server does after its moves — time them.
func tick_timers_only(tick: int) -> void:
	_tick = tick
	_feed_timers()


## Move every player, then time the tick with the position the move produced.
func _simulate_tick(step: float) -> void:
	maps.advance(step)

	for id in players:
		(players[id] as G2GPlayer).simulate(_tick, step)

	# After the moves and before the timers, which is where every per-tick measurement
	# in this game belongs: the counters it reads are what the move just produced, and
	# the distance it measures is the distance that move covered.
	if progress != null:
		progress.sample(step)

	# The three layers, in the order their inputs are produced. Combat resolves shots
	# against the world as it ends the tick — half a tick of movement at surf speeds
	# is two metres, which at range is a different part of the map. The hunters
	# perceive where the players ended up. The props are only a rate limit.
	if combat != null:
		combat.tick(step)

	if hunters != null:
		hunters.tick(step)

	if props != null:
		props.tick(step)

	_feed_timers()


func _feed_timers() -> void:
	for id in players:
		var player: G2GPlayer = players[id]
		if player.timer == null or player.replay != null:
			continue
		var sample: DotTimerSample = _samples[id]
		player.fill_sample(sample)
		timers.tick_player(
			id, sample.position, sample.velocity, sample.grounded, sample.alive,
			player.controller.state.yaw, player.controller.state.pitch, sample.buttons
		)


# --- Maps ------------------------------------------------------------------

func change_map(id: StringName) -> DotResult:
	return await maps.change_to(id)


func _on_map_changing(_from: DotMapDef, _to: DotMapDef) -> void:
	remove_player(GHOST_ID)
	for id in players:
		var player: G2GPlayer = players[id]
		if player.timer != null:
			player.timer.stop(DotTimer.REASON_RESET)


func _on_map_changed(map: DotMapDef, loaded: Node) -> void:
	var g2g_map := loaded as G2GMap

	# An imported map is data, and this is where it learns which data. It must happen
	# before `timer_zones()` below: the zones come out of the manifest, so asking an
	# unbuilt map for them returns an empty set and the map plays with no start, no
	# finish and no pit -- with nothing erroring, because an empty zone set is a
	# legitimate thing for a map to have.
	var bsp := loaded as G2GBspMap
	if bsp != null:
		bsp.build_from(map)

	var zones: DotTimerZoneSet = g2g_map.timer_zones() if g2g_map != null else null

	if zones == null and maps.zones_json != "":
		var parsed := DotTimerZoneSet.from_json(maps.zones_json)
		if parsed.ok:
			zones = parsed.value

	timers.set_zones(zones)

	for id in players:
		spawn_player(id)

	map_ready.emit(map)
	spawn_ghost()


func _on_map_over(_map: DotMapDef, reason: StringName) -> void:
	var next := maps.rotation.choose(players.size())
	if next == null:
		return

	DotLog.info(CHANNEL, "changing map", {"reason": String(reason), "to": String(next.id)})

	var changed: DotResult = await change_map(next.id)
	if not changed.ok:
		maps.time_limit.extend(120.0)


func rock_the_vote(player_id: StringName) -> bool:
	return maps.rock_the_vote(player_id, players.size())


# --- Timer events ----------------------------------------------------------

func _on_effect_requested(player_id: StringName, zone: DotTimerZone) -> void:
	var player: G2GPlayer = players.get(player_id)
	if player == null:
		return

	match zone.kind:
		DotTimerZone.Kind.RESPAWN, DotTimerZone.Kind.SLAY:
			spawn_player(player_id)
		DotTimerZone.Kind.TELEPORT:
			player.teleport(zone.destination, zone.destination_yaw)
		_:
			pass


func _on_player_finished(player_id: StringName, run: DotTimerRun) -> void:
	var player: G2GPlayer = players.get(player_id)
	if player == null:
		return

	# Statistics in genre units, because that is what a record's viewer reads.
	var stats := player.controller.stats.to_dictionary()
	stats["max_speed"] = G2GUnits.to_units(float(stats.get("max_speed", 0.0)))
	stats["avg_speed"] = G2GUnits.to_units(float(stats.get("avg_speed", 0.0)))
	stats["max_jump_speed"] = G2GUnits.to_units(float(stats.get("max_jump_speed", 0.0)))

	timers.note_stats(player_id, stats)
	player.controller.stats.reset()
	player.finished.emit(run)


func _on_record_accepted(record: DotTimerRecord, _previous: DotTimerRecord, rank: int) -> void:
	var scope := {
		"map": String(record.map_id), "track": str(record.track), "style": String(record.style_id),
	}

	await boards.submit(&"fastest", scope, record.player_id, record.player_name, record.time)

	var totals := DotStatSet.new()
	totals.add(&"points", record.points)
	totals.add(&"completions", 1.0)
	await boards.add_stats(record.player_id, totals)
	await boards.publish_stat(&"points", {}, record.player_id, record.player_name, &"points")

	var who := timers.player(record.player_id)
	if who != null:
		run_filed.emit(record.player_id, who.last_finished, rank, "")
		# The ghost chases the server record: a new one replaces it on the spot.
		if rank == 1 and who.last_replay != null and replays.offer(who.last_replay, record):
			if maps.current != null and record.map_id == maps.current.id:
				spawn_ghost(record.track, record.style_id)


func _on_record_refused(player_id: StringName, run: DotTimerRun, reason: String) -> void:
	run_filed.emit(player_id, run, 0, reason)


# --- Diagnostics -----------------------------------------------------------

func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("map          %s" % (String(maps.current.id) if maps != null and maps.current != null else "-"))
	out.append("players      %d" % players.size())
	out.append("tick rate    %d%s" % [
		tick_rate,
		"" if timers.tick_rate_matches_engine() else " (DISAGREES with the engine's %d)" % Engine.physics_ticks_per_second,
	])
	out.append("autobhop     %s" % ("on" if config.auto_bhop else "off"))
	out.append("movement     airaccel %.0f  accel %.1f  gravity %.0f  friction %.1f  maxvel %.0f" % [
		config.air_accelerate, config.accelerate, config.gravity, config.friction, config.max_velocity,
	])
	out.append("time left    %s" % maps.time_limit.formatted_remaining())

	if progress != null:
		out.append_array(progress.describe_lines())

	if combat != null:
		out.append_array(combat.describe_lines())

	if hunters != null:
		out.append_array(hunters.describe_lines())

	if props != null:
		out.append_array(props.describe_lines())

	for id in players:
		out.append("  %s" % str((players[id] as G2GPlayer).describe()))
	return out


func _exit_tree() -> void:
	DotRegistry.unregister_instance(DotRegistry.scoped_name(SERVICE, service_scope), self)
