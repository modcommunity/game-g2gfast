class_name G2GProps
extends Node

## Blocks an admin can place on a course, and take away again.
##
## [b]Not a sandbox.[/b] game-playground is the sandbox and this is the timer server;
## what a records community actually places is a practice line, a temporary block on
## the section everybody fails, and a marker at the spot people keep asking about.
## Every one of those wants to stay where it was put, so a prop here is spawned
## [b]frozen[/b] — which is the opposite default from a sandbox's and the reason
## `g2g_prop_body.gd` has a `starts_frozen` export at all.
##
## [b]The sizes are in the genre's units and converted at one boundary[/b], like
## everything else an operator touches in this game. A block "64 wide" is a thing a
## mapper in this genre can picture; 1.22 metres is not.
##
## [b]Placed props are not part of a run.[/b] `only_practice` is on by default, and
## while it is on a player with a block under them is a player whose run is not
## rankable — the same rule dot-timer already applies to a practice checkpoint, for the
## same reason. A leaderboard where one time was set over a block somebody placed is a
## leaderboard nobody trusts.
##
## [codeblock]
## var props := G2GProps.new()
## props.game = game
## add_child(props)
## props.setup()
## props.place(&"u7", G2GProps.BLOCK, where_they_are_looking)
## [/codeblock]

const CHANNEL := "g2g.props"

const BLOCK := &"g2g_block_small"
const BLOCK_WIDE := &"g2g_block_medium"
const PLATFORM := &"g2g_platform"

## A prop was placed. Carries who placed it.
signal prop_placed(player_id: StringName, prop: DotPropInstance)

@export_group("Rules")

## Whether ordinary players may place anything, or only admins.
##
## Off. A block placed on a course changes the course, and changing the course is an
## admin's decision on a server whose whole product is comparable times.
@export var players_may_place: bool = false

## Whether a run made while anything is placed is refused a record.
##
## [b]On, and it is the setting that makes the feature safe to ship.[/b] See the class
## note: a board with one time set over a placed block is a board nobody trusts, and
## the alternative — trusting an admin to clear up — is a rule enforced by memory.
@export var only_practice: bool = true

var game: G2GGame = null

var spawner: DotPropSpawner = null

var _world: Node3D = null
var _limits: DotPropLimits = null

## Per player, because a tool holds what that player has. A single tool object is a
## single held prop, so the second player to press the button takes the first player's
## block out of their hands.
var _phys_guns: Dictionary = {}


func setup() -> DotResult:
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "Props need a game.")

	_world = Node3D.new()
	_world.name = "Props"
	add_child(_world)

	_limits = limits()

	spawner = DotPropSpawner.new()
	spawner.name = "PropSpawner"
	spawner.catalogue = catalogue()
	spawner.limits = _limits
	spawner.authoritative = game.authoritative
	spawner.world_ref = DotNodeRef.of_path(NodePath("../Props"))
	add_child(spawner)

	spawner.spawned.connect(_on_spawned)

	game.map_ready.connect(_on_map_ready)

	return DotResult.success(self)


## What can be placed. Three sizes, in the genre's units.
##
## 32, 64 and 128 units — the grid this genre's maps are built on — converted at the
## one boundary [G2GUnits] owns. A block that is "about half a metre" is a block a
## mapper cannot line up with anything.
static func catalogue() -> DotPropCatalogue:
	var out := DotPropCatalogue.new()
	out.meta = {"game": "g2gfast"}

	for def in [_block(), _block_wide(), _platform()]:
		var added := out.add(def)

		if not added.ok:
			DotLog.warn(CHANNEL, "a prop could not be catalogued", {
				"prop": String(def.id), "why": added.error.message
			})

	return out


static func _block() -> DotPropDef:
	var def := DotPropDef.make(BLOCK, "res://props/g2g_block_small.tscn")
	def.display_name = "Block (32u)"
	def.category = &"practice"
	def.size = DotPropDef.Size.SMALL
	def.mass = 200.0
	def.cost = 1
	return def


static func _block_wide() -> DotPropDef:
	var def := DotPropDef.make(BLOCK_WIDE, "res://props/g2g_block_medium.tscn")
	def.display_name = "Block (64u)"
	def.category = &"practice"
	def.size = DotPropDef.Size.MEDIUM
	def.mass = 400.0
	def.cost = 2
	return def


static func _platform() -> DotPropDef:
	var def := DotPropDef.make(PLATFORM, "res://props/g2g_platform.tscn")
	def.display_name = "Platform (128u)"
	def.category = &"practice"
	def.size = DotPropDef.Size.LARGE
	def.mass = 900.0
	def.cost = 3
	return def


static func limits() -> DotPropLimits:
	var out := DotPropLimits.new()

	# Small. A practice line is a handful of blocks; a budget that allows a staircase
	# to the end zone allows a staircase to the end zone.
	out.per_player_budget = 16
	out.per_player_frozen = 16
	out.spawn_interval = 0.3
	out.world_budget = 64
	out.clean_up_on_leave = true
	out.undo_depth = 16
	out.max_size = DotPropDef.Size.LARGE

	# In metres, converted from the genre's numbers: 2048 units of reach and a hold
	# distance between 64 and 512.
	out.grab_range = G2GUnits.to_metres(2048.0)
	out.grab_mass_limit = 0.0
	out.hold_distance_min = G2GUnits.to_metres(64.0)
	out.hold_distance_max = G2GUnits.to_metres(512.0)

	return out


# --- Placing ---------------------------------------------------------------

## Places one prop for a player.
##
## Refused for a non-admin unless [member players_may_place] is on; the caller decides
## who is an admin, because only the host holds the session.
func place(
	player_id: StringName, prop_id: StringName, at: Vector3, is_admin: bool = false
) -> DotPropInstance:
	if spawner == null:
		return null

	if not is_admin and not players_may_place:
		return null

	return spawner.spawn(prop_id, player_id, at)


func undo(player_id: StringName) -> bool:
	return spawner.undo(player_id) if spawner != null else false


func clear_player(player_id: StringName) -> int:
	return spawner.clear_player(player_id) if spawner != null else 0


func clear() -> int:
	return spawner.clear_all(DotPropSpawner.REASON_ADMIN) if spawner != null else 0


func count() -> int:
	return spawner.world_count() if spawner != null else 0


## Whether a run made right now can be ranked.
##
## [b]Read by the timer through the game, not enforced here.[/b] dot-timer already has
## the concept — a practised run is one that used a checkpoint and is not a record —
## and this is the same statement about a different aid. What a caller does with the
## answer is refuse the record, not refuse the run: a player practising should still
## see their time.
func taints_records() -> bool:
	return only_practice and count() > 0


## Moves a block an admin is already looking at, rather than placing another.
##
## [b]This is what a practice line is actually built with.[/b] Placing a block puts one
## roughly where you are looking; getting it onto the ledge you meant needs a nudge,
## and a gun is the nudge. `DotPhysGun` was built per player here and reachable from
## nothing until the family's own detector — a public method whose name occurs once in
## its repository — found it.
##
## [b]It re-freezes on release.[/b] `DotPhysGun.grab` unfreezes what it picks up,
## because a frozen prop being dragged is a contradiction the solver resolves by doing
## something alarming — so a block let go over a gap would fall through it, and every
## block on this server is meant to stay where it was put.
func nudge(
	player_id: StringName, origin: Vector3, direction: Vector3, delta: float
) -> bool:
	if spawner == null or not spawner.authoritative:
		return false

	var gun := phys_gun(player_id)

	if gun.held != null and gun.held.is_alive():
		gun.hold(origin, direction, Basis.looking_at(direction, Vector3.UP), delta)
		return true

	var space: Variant = _space()

	if space == null:
		return false

	return gun.grab(
		space, origin, direction, Basis.looking_at(direction, Vector3.UP)
	).ok


## Lets go of what a player was moving, and freezes it where it ended up.
func drop(player_id: StringName) -> bool:
	if not _phys_guns.has(player_id):
		return false

	var gun: DotPhysGun = _phys_guns[player_id]
	var was := gun.release()

	if was == null:
		return false

	# Frozen again. Every block on this server is meant to stay where it was put, and
	# `grab` unfroze it to move it.
	DotPhysGun.set_frozen(was, true)
	return true


## The physics space the tools trace in, or null when there is none.
##
## Typed [Variant] because `DotPropTool.target` takes one — the tools are written so
## they compile in a project that is not in a 3D scene at all, which is how they are
## tested headlessly.
##
## [b]Taken off the world node rather than off this one.[/b] `G2GProps` is a plain
## [Node] and `get_world_3d()` does not exist on one; dot-npc's own notes record the
## same mistake, where a duck-typed branch around it would not even compile because
## GDScript cannot infer what such a branch returns.
func _space() -> Variant:
	if _world == null or not _world.is_inside_tree():
		return null

	# Typed explicitly. `var x := f()` where f returns Variant is a parse ERROR under
	# these projects' warning settings.
	var world: World3D = _world.get_world_3d()
	return world.direct_space_state if world != null else null


## This player's physics gun, made on first use.
func phys_gun(player_id: StringName) -> DotPhysGun:
	if not _phys_guns.has(player_id):
		var gun := DotPhysGun.new()
		gun.spawner = spawner
		gun.wielder = player_id
		_phys_guns[player_id] = gun

	return _phys_guns[player_id]


## Drops what a player was holding and forgets their tool.
##
## Without it the tool outlives the session, and the next player given the same id
## inherits whatever the last one was carrying — a block frozen in mid-air that nobody
## owns.
func release_player(player_id: StringName) -> void:
	if _phys_guns.has(player_id):
		(_phys_guns[player_id] as DotPhysGun).release()
		_phys_guns.erase(player_id)

	if spawner != null:
		spawner.player_left(player_id)


func tick(delta: float) -> void:
	if spawner != null:
		spawner.advance(delta)

	_carry(delta)


## Keeps every held block where its holder is looking. Once per tick.
##
## [b]A grab happens once and a held prop moves every tick.[/b] A layer that only
## called `grab` would give an admin a block that stayed exactly where it was picked
## up, which reads as the physics gun not working rather than as a missing call.
func _carry(delta: float) -> void:
	if game == null:
		return

	for id in _phys_guns.keys():
		var gun: DotPhysGun = _phys_guns[id]

		if gun.held == null or not gun.held.is_alive():
			continue

		var player: G2GPlayer = game.players.get(id)

		if player == null:
			gun.release()
			continue

		var aim := player.aim_direction()
		gun.hold(
			player.eye_position(), aim, Basis.looking_at(aim, Vector3.UP), delta
		)


func _on_spawned(prop: DotPropInstance) -> void:
	# [b]On the prop layer, which is what makes blocks touch each other.[/b] A spawned
	# block is a `RigidBody3D` on Godot's default layer 1 masking layer 1, so two placed
	# in the same spot passed through one another — a practice line whose blocks were
	# solid against the map and transparent to their own kind. `prop`'s row in the
	# layout is [world, player, npc, prop, projectile, vehicle], which is the whole of
	# what a stacked practice block needs.
	if game != null and game.player_stack != null and prop.node != null:
		var _put := game.player_stack.classify(prop.node, &"prop")

	prop_placed.emit(prop.owner_id, prop)

	if game != null and game.progress != null and prop.owner_id != &"":
		game.progress.record(prop.owner_id, G2GStats.PROPS_SPAWNED)


func _on_map_ready(_map: DotMapDef) -> void:
	# Every block belonged to the map that was just replaced, and its nodes are
	# children of this node rather than of the world — so nothing freed them, and a
	# block left floating where a ramp used to be has no floor under it.
	if spawner != null:
		spawner.clear_all(DotPropSpawner.REASON_CLEANUP)

	for id in _phys_guns.keys():
		(_phys_guns[id] as DotPhysGun).release()


func describe() -> Dictionary:
	return {
		"props": count(),
		"players_may_place": players_may_place,
		"taints_records": taints_records(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("props        %d placed%s" % [
		count(), "  (records off)" if taints_records() else ""
	])
	return out
