extends "res://addons/dot_npc_ai/runtime/dot_npc_ai_brain.gd"

## How a hunter decides: chase the runner, or patrol the course.
##
## Extended by PATH, not by name. A script inside a mounted dot-cloud pack cannot
## resolve a `class_name`, and a rule you only follow where it is needed is a rule
## nobody notices you have broken.
##
## [b]A hunter cannot catch a player who is running well, and that is the point.[/b]
## The fastest thing here does 8 m/s and a bhop player on a good line does forty. What
## a hunter punishes is stopping — a missed jump, a fall, a stage restart — which is
## exactly the failure a timer already punishes, made visible. So the tree is two
## branches and the interesting one is not the chase:
##
## [codeblock]
## selector
##   sequence (reactive)  has a target? -> close on it -> strike
##   action               walk the course, which is where the players will be
## [/codeblock]
##
## The patrol is `DotNpcDirectorFlow`'s doing rather than this file's: a timer map IS a
## critical path — start pad, stages, end — and the director already knows it, so a
## hunter with nothing to chase walks toward the flow position ahead of it. That is
## what puts them where a runner is going rather than where a runner was.

const KEY_HURT_BY := &"g2g.hurt_by"

## Where a brain reaches the game. See [G2GHunters].
const HUNTERS_SERVICE := &"g2g_hunters"

var _last_attack: float = -999.0

## How far along the course this hunter is patrolling to, 0..1.
var _patrol_flow: float = 0.0

var _hunters: Object = null


## Assigns the character BEFORE the base class looks at it.
##
## [b]`_build` is too late and the failure is silent.[/b]
## [method DotNpcAiBrain._npc_ready] seeds the character from the instance id and puts
## it on the context, both before calling `_build` — so a brain that assigns it inside
## `_build` gets neither, every hunter of a kind shares its preset's seed, and
## `ctx.character` is null for every node in the tree.
func _npc_ready() -> void:
	character = _character_for(npc.def.id if npc != null and npc.def != null else &"")
	super()


func _build() -> void:
	_patrol_flow = DotNpcAiNode.deterministic_unit(
		npc.instance_id if npc != null else 0, 5501
	)

	var fight_children: Array[DotNpcAiNode] = [
		DotNpcAiLeaf.Condition.new(&"has a target", _has_target),
		DotNpcAiLeaf.Action.new(&"close in", _close_in),
		DotNpcAiLeaf.Action.new(&"strike", _strike),
	]

	var root_children: Array[DotNpcAiNode] = [
		# Reactive, which is dot-npc-ai's own warning made into an idiom: a plain
		# sequence resumes at the child that returned RUNNING and never re-asks its
		# guard, so a hunter chases a target it no longer has — for ever, because the
		# thing that would clear the chase is the condition it stopped asking.
		DotNpcAiSequence.reactive_with(&"hunt", fight_children),
		DotNpcAiLeaf.Action.new(&"patrol", _patrol),
	]

	tree = DotNpcAiSelector.new(&"root", root_children)


func _has_target(_ctx: DotNpcAiContext) -> bool:
	return npc != null and npc.has_target()


func _close_in(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	if npc == null or not npc.is_alive():
		return DotNpcAiNode.Status.FAILURE

	var to := target_position(npc.position())
	var reach := tune(&"reach", 2.0)

	var flat := to - npc.position()
	flat.y = 0.0

	if flat.length() <= reach:
		halt()
		return DotNpcAiNode.Status.SUCCESS

	if not has_reacted():
		halt()
		return DotNpcAiNode.Status.RUNNING

	# With spacing, because a course is narrow: three hunters converging on one runner
	# in a corridor climb each other, and the one on top has a horizontal offset of
	# nothing from the one below — so it chases perfectly at a dead stop with every
	# number about it reading correctly.
	steer_with_spacing(
		to, npc.def.move_speed if npc.def != null else 4.0, ctx.delta, 1.4
	)

	return DotNpcAiNode.Status.RUNNING


func _strike(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	if npc == null or not npc.is_alive() or not npc.has_target():
		return DotNpcAiNode.Status.FAILURE

	if ctx.now - _last_attack < tune(&"attack_interval", 1.2):
		# RUNNING, not FAILURE. Failing would drop the sequence and send the selector
		# to `patrol`, so a hunter standing over somebody between swings would turn
		# round and walk off — which looks exactly like losing interest.
		halt()
		face(target_position(npc.position()) - npc.position())
		return DotNpcAiNode.Status.RUNNING

	var flat := target_position(npc.position()) - npc.position()
	flat.y = 0.0

	# Re-tested rather than trusted from `_close_in`. A reactive sequence re-runs its
	# condition, not its earlier children, so a runner who got moving again while the
	# interval ran would otherwise be hit from anywhere.
	if flat.length() > tune(&"reach", 2.0) * 1.2:
		return DotNpcAiNode.Status.FAILURE

	_last_attack = ctx.now
	_deal_damage(npc.target_id, tune(&"damage", 20.0))

	return DotNpcAiNode.Status.SUCCESS


## Walks the course rather than wandering.
##
## [b]This is the branch a timer map makes interesting.[/b] A wandering hunter on a
## linear course spends most of its life in a corner nobody passes; one walking the
## flow is always somewhere a runner is going to be. The flow comes from the director,
## which built it from the map's own zones, so nothing here knows what a stage is.
func _patrol(ctx: DotNpcAiContext) -> DotNpcAiNode.Status:
	if npc == null or not npc.is_alive():
		return DotNpcAiNode.Status.FAILURE

	if _hunters == null:
		_hunters = DotRegistry.get_service(HUNTERS_SERVICE)

	var goal := npc.position()

	if _hunters != null and _hunters.has_method("patrol_point"):
		var found: Variant = _hunters.call("patrol_point", _patrol_flow)

		if found is Vector3:
			goal = found

	if goal.distance_to(npc.position()) < 3.0:
		# Arrived. Move the target along the course rather than stopping, and wrap —
		# a hunter that walked to the end and stood there is a hunter nobody meets
		# twice.
		_patrol_flow = fmod(_patrol_flow + 0.2, 1.0)
		return DotNpcAiNode.Status.RUNNING

	steer_with_spacing(
		goal, (npc.def.move_speed if npc.def != null else 4.0) * 0.5, ctx.delta, 1.4
	)

	return DotNpcAiNode.Status.RUNNING


func _npc_damaged(_amount: float, by: StringName) -> void:
	if blackboard != null and by != &"":
		# A memory with a lifetime rather than a field. The blackboard forgets, which
		# is what stops a hunter bearing a grudge against somebody who left.
		blackboard.put(KEY_HURT_BY, by, 8.0)


func _deal_damage(victim: StringName, amount: float) -> void:
	if _hunters == null:
		_hunters = DotRegistry.get_service(HUNTERS_SERVICE)

	if _hunters == null or not _hunters.has_method("hunter_attack"):
		return

	_hunters.call("hunter_attack", npc, victim, amount)


## Who a hunter is, by kind. Two presets rather than one with a multiplier, because a
## multiplier makes every hunter the same hunter at a different speed.
static func _character_for(kind: StringName) -> DotNpcAiCharacter:
	if kind == &"g2g_sprinter":
		var sprinter := DotNpcAiCharacter.hard()
		sprinter.id = &"g2g.sprinter"
		sprinter.reaction_time = 0.15
		sprinter.memory_time = 14.0
		sprinter.aggression = 0.85
		sprinter.self_preservation = 0.6
		return sprinter

	var stalker := DotNpcAiCharacter.normal()
	stalker.id = &"g2g.stalker"
	stalker.reaction_time = 0.5
	stalker.memory_time = 8.0
	stalker.aggression = 0.6
	stalker.self_preservation = 0.2
	return stalker
