class_name G2GPlayerStack
extends Node

## The player-facing addons, stood up once and bound to the timer server.
##
## [b]A timer server is the odd one out in this family and the layer still fits.[/b]
## There is no match, no round, no respawn queue and — mostly — no killing. What there
## is, is a session that lasts for hours, people who join and leave and come back, a
## spectator seat that is genuinely useful because watching a good run is the point, and
## a start zone that is a spawn by any other name.
##
## So this stands up the same six addons `ArenaPlayerStack` does and binds them to what
## g2gfast actually has:
##
## [codeblock]
## dot-physics  128 Hz and the shooter layout, because that is what the movement is
## dot-player   the roster, with a long reconnect window: a run takes minutes
## dot-team     one playing side and a spectator side — free-for-all is ONE team
## dot-player-class  one class; the movement styles are dot-timer's, not this layer's
## dot-spawn    the map's start, as a site the richer selector can reason about
## dot-team's spectate half, over the G2GSpectate manager this game already has
## [/codeblock]
##
## [b]Why one team and not none.[/b] Free-for-all modelled as "no teams" makes every
## consumer branch on whether teams exist, and the branch nobody writes is the one that
## matters. One playing side with friendly fire on says the same thing and costs a
## consumer nothing — and it is what gives the spectator seat somewhere to be.

const CHANNEL := "g2g.stack"

const SERVICE := &"g2g_player_stack"

@export var register_service: bool = true

## Whether to apply a physics profile. Off on a client: the server's rate is what counts.
@export var apply_physics: bool = true

var game: G2GGame = null

var physics: DotPhysicsWorld = null
var roster: DotPlayerRoster = null
var teams: DotTeamRoster = null
var classes: DotPlayerClassManager = null
var spawns: DotSpawnDirector = null
var spectate: DotTeamSpectate = null

var _registered: bool = false


func setup(p_game: G2GGame) -> DotResult:
	if p_game == null:
		return DotResult.fail(DotError.CODE_INVALID, "No game to bind to.")

	game = p_game

	var built := _build_physics()

	if not built.ok:
		return built

	_build_roster()
	_build_teams()
	_build_classes()
	_build_spawns()
	_build_spectate()

	game.player_added.connect(_on_player_added)
	game.player_removed.connect(_on_player_removed)
	game.map_ready.connect(_on_map_ready)

	if register_service:
		DotRegistry.register(
			DotRegistry.scoped_name(SERVICE, game.service_scope), self
		)
		_registered = true

	DotLog.info(CHANNEL, "player stack up", {"tick_rate": game.tick_rate})
	return DotResult.success(null)


func _exit_tree() -> void:
	if _registered:
		DotRegistry.unregister_instance(
			DotRegistry.scoped_name(SERVICE, game.service_scope), self
		)


# --- Building ---------------------------------------------------------------

func _build_physics() -> DotResult:
	if not apply_physics:
		return DotResult.success(null)

	physics = DotPhysicsWorld.new()
	physics.name = "Physics"
	physics.profile = DotPhysicsProfile.arcade_shooter()

	# [b]The game's rate, not the preset's.[/b] g2gfast counts in 128ths of a second
	# and a run set at one rate is not comparable with one set at another — dot-timer's
	# whole sub-tick design exists for that. A physics profile quietly running at a
	# different rate would move every prop at a different speed from every player.
	physics.profile.tick_rate = game.tick_rate
	physics.profile.gravity_3d = game.tunables.gravity if game.tunables != null else 20.0

	physics.layout = DotPhysicsLayout.shooter_3d()
	physics.surfaces = DotPhysicsSurfaceSet.standard()
	physics.register_service = false
	physics.write_layer_names = false
	add_child(physics)

	return physics.setup().wrap("g2gfast's physics profile")


func _build_roster() -> void:
	roster = DotPlayerRoster.new()
	roster.name = "Roster"
	roster.authoritative = game.authoritative
	roster.register_service = false

	var config := DotPlayerConfig.new()
	config.tick_rate = game.tick_rate
	config.max_players = 64
	# Five minutes. A run takes minutes and a player who drops mid-run and comes
	# straight back should still be the same person to the boards.
	config.reconnect_window_sec = 300.0
	roster.config = config
	add_child(roster)


func _build_teams() -> void:
	teams = DotTeamRoster.new()
	teams.name = "Teams"
	teams.authoritative = game.authoritative
	teams.register_service = false
	teams.teams = DotTeamSet.free_for_all()
	teams.policy = DotTeamPolicy.free_for_all()
	teams.policy.tick_rate = game.tick_rate
	teams.alive_fn = _alive_of_key
	add_child(teams)

	var res := teams.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "team roster", {"why": res.error.message})


func _build_classes() -> void:
	classes = DotPlayerClassManager.new()
	classes.name = "Classes"
	classes.authoritative = game.authoritative
	classes.register_service = false

	# [b]One class, and the movement styles are deliberately not classes.[/b] A style
	# here is a dot-timer concept — it changes what a run is worth and what the leader
	# board compares it against — and modelling it as a player class would put the
	# ranking rules in a layer that knows nothing about ranking.
	classes.catalogue = DotPlayerClassCatalogue.single(100.0)
	classes.rules = DotPlayerClassRules.instant()
	classes.team_fn = func(key: String) -> StringName: return teams.team_of(key)
	classes.alive_fn = _alive_of_key
	add_child(classes)

	var res := classes.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "class manager", {"why": res.error.message})


func _build_spawns() -> void:
	spawns = DotSpawnDirector.new()
	spawns.name = "Spawns"
	spawns.tick_rate = game.tick_rate
	spawns.register_service = false
	spawns.rules = DotSpawnRules.single_start()
	add_child(spawns)

	refresh_spawns()


## Re-reads the map's start points. Call after a map change.
##
## One site per track, because that is what a course is: the main run starts in one
## place and every bonus starts in its own. `single_start` picks the first that admits
## the request, and the track is carried in the site's metadata so a mode that wants a
## specific one can ask with a condition.
func refresh_spawns() -> void:
	if spawns == null or game == null:
		return

	spawns.clear_sites()

	var map := game.current_map_node()

	if map == null:
		return

	# Every track the map could have: the main run and up to eight bonuses. A map with
	# no bonus answers the origin for those, which is the skip below — reading
	# DotTimerTrack's own range rather than guessing a count is what keeps this right
	# when a map gains a ninth.
	for track in range(DotTimerTrack.MAIN, DotTimerTrack.COUNT):
		var at := map.spawn_for(track)

		if at.is_equal_approx(Vector3.ZERO):
			continue

		var site := DotSpawnSite.point(
			StringName("start_%d" % track), at, map.spawn_yaw_for(track)
		)
		site.meta = {"track": track}
		site.priority = 10 if track == DotTimerTrack.MAIN else 0
		site.id = StringName(DotTimerTrack.short_name_of(track))
		spawns.add_site(site)

	DotLog.debug(CHANNEL, "start sites", {"count": spawns.sites().size()})


func _build_spectate() -> void:
	spectate = DotTeamSpectate.new()
	spectate.name = "Spectate"
	spectate.teams = teams
	spectate.register_service = false
	spectate.rules = DotTeamSpectateRules.open()
	spectate.alive_fn = _alive_of_key
	spectate.pose_fn = _pose_of_key
	# No rounds on a timer server, so nothing is ever "mid-round" and the end-of-round
	# relaxation is permanently on. Said explicitly rather than left to the default,
	# because the default is the cautious one and would be wrong here.
	spectate.round_live_fn = func() -> bool: return false

	# [b]The manager this game already has, rather than a second one.[/b] G2GSpectate
	# wraps a DotSpectatorManager with g2gfast's own rules and its own pose lookup;
	# building another would give the server two spectator systems disagreeing about
	# who is watching whom.
	if game.spectate != null and game.spectate.manager != null:
		spectate.spectators = game.spectate.manager

	add_child(spectate)

	var res := spectate.setup()

	if not res.ok:
		DotLog.error(CHANNEL, "team spectate", {"why": res.error.message})


# --- Keeping in step --------------------------------------------------------

func _on_player_added(player: G2GPlayer) -> void:
	if not game.authoritative:
		return

	var key := String(player.player_id)
	var res := roster.join(key, player.display_name, 0, 0)

	if not res.ok:
		DotLog.warn(CHANNEL, "player not added to the roster", {
			"key": key, "why": res.error.message
		})
		return

	var _team := teams.add(key, 0)
	var _class := classes.add(key)
	# A timer server has no death: somebody who exists is in the world, and a roster
	# that never said so would report an empty session to every consumer.
	var _alive := roster.set_alive(key, true)


func _on_player_removed(id: StringName) -> void:
	var key := String(id)

	if not roster.authoritative:
		return

	spectate.end(key)
	classes.remove(key)
	var _left := teams.remove(key)
	var _held := roster.note_disconnected(key, 0)


func _on_map_ready(_map: DotMapDef) -> void:
	refresh_spawns()


## One tick of what this node runs on its own.
func tick(current_tick: int) -> void:
	if not game.authoritative:
		return

	var _dropped := roster.advance(current_tick)
	spectate.advance(current_tick)


# --- Reading ----------------------------------------------------------------

## Where a player should start, asked of the richer selector.
##
## Offered rather than imposed: `G2GGame.spawn_player` uses the map's own start for the
## player's track, which is correct and needs nothing from this layer. A mode that wants
## a start chosen by condition — a course with alternate openings, a lobby that spreads
## arrivals out — calls this instead.
func choose_start(id: StringName) -> DotResult:
	var key := String(id)
	return spawns.choose(
		DotSpawnRequest.make(key, teams.team_of(key), classes.class_of(key), 0)
	)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("--- player stack")

	if physics != null:
		out.append_array(physics.describe_lines())

	out.append_array(roster.describe_lines())
	out.append_array(teams.describe_lines())
	out.append_array(spawns.describe_lines())
	out.append_array(spectate.describe_lines())
	return out


func describe() -> Dictionary:
	return {
		"players": roster.count(),
		"connected": roster.connected_count(),
		"starts": spawns.sites().size(),
		"viewers": spectate.viewers().size(),
	}


# --- The callables the addons are given -------------------------------------

func _alive_of_key(key: String) -> bool:
	return game.players.has(StringName(key))


func _pose_of_key(key: String) -> Transform3D:
	var player: G2GPlayer = game.players.get(StringName(key))

	if player == null or player.controller == null:
		return Transform3D.IDENTITY

	return player.controller.eye_transform()
