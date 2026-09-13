extends Node

const G2GGame := preload("g2g_game.gd")
const G2GPlayer := preload("g2g_player.gd")

## Status effects on a timer server, and the one rule that makes them safe here.
##
## [b]A movement effect is a style, and a style you did not choose is a record you did
## not set.[/b] Everything else in this game exists to make a run comparable with a run
## somebody else set on another server at another tick rate — sub-tick zone crossings,
## a tick rate taken from `sv_tickrate`, styles paired between dot-player-controller and
## dot-timer by id. An effect that quietly multiplies `max_speed` by 1.35 undoes all of
## it, and the player would have no way of knowing it had happened.
##
## So there are two classes of effect here and the split is enforced rather than
## documented:
##
## - **Combat effects** — a bleed, a burn, a damage buff — apply to anybody at any time.
##   They cannot change a time.
## - **Movement effects** — a slow, a haste — are refused outright while a ranked run is
##   live, and **taint** the run when a server has chosen to allow them anyway.
##   `DotTimerRun.tainted` is the field dot-timer already has for exactly this, and it
##   is what stops a hunted run reaching a leaderboard beside a clean one.
##
## The second half is why the hunters are interesting rather than annoying: being
## chased has to cost you something, and the thing it costs you is the record.

const CHANNEL := "g2g.effects"

## What a hunter's swipe leaves behind. Movement, and therefore run-tainting.
const MAULED := &"g2g_mauled"

## A bleed. Damage over time, safe on a live run.
const BLEEDING := &"g2g_bleeding"

## A boost pad, or a server's own reward. Movement.
const HASTE := &"g2g_haste"

var game: G2GGame = null

var manager: DotEffectManager = null

## Whether a movement effect may be applied to somebody in a ranked run at all.
##
## Off. A server that wants hunted runs to count anyway turns it on and every such run
## is tainted, which is the honest version of the same thing.
@export var allow_movement_during_runs: bool = false


func setup() -> DotResult:
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "G2GEffects needs a game.")

	manager = DotEffectManager.new()
	manager.name = "EffectManager"
	manager.authoritative = game.authoritative
	manager.rules = DotEffectRules.new()
	manager.rules.downed_enabled = false
	add_child(manager)

	var res := manager.setup(table(game.tick_rate))
	if not res.ok:
		return res.wrap("g2gfast effects")

	manager.damaged.connect(_on_damaged)
	return DotResult.success(null)


## Built from the tick rate rather than exported at one. This game runs at 128 and its
## browser shell exported 60, which is the disagreement that cost it a whole leaderboard.
static func table(rate: int) -> Array[DotEffectDef]:
	var mauled := DotEffectDef.speed(MAULED, 0.65, 3 * rate)
	mauled.display_name = "Mauled"
	mauled.label = "SLOW"

	var bleeding := DotEffectDef.burning(BLEEDING, 2.0, 5 * rate)
	bleeding.tick_interval = rate / 2
	bleeding.damage_type = &"bleed"
	bleeding.display_name = "Bleeding"
	bleeding.label = "BLD"

	var haste := DotEffectDef.speed(HASTE, 1.25, 5 * rate)
	haste.display_name = "Haste"
	haste.label = "SPD"

	return [mauled, bleeding, haste]


## Whether an effect changes how somebody moves.
##
## Asked of the definition rather than of a list of ids, so an effect added later is
## classified by what it does rather than by somebody remembering to name it here.
static func is_movement(def: DotEffectDef) -> bool:
	if def == null:
		return false
	return not is_equal_approx(def.move_speed_scale, 1.0) \
		or not is_equal_approx(def.jump_scale, 1.0)


## Apply an effect, subject to the rule above.
func apply(id: StringName, player_id: StringName, source: StringName = &"") -> DotResult:
	if manager == null:
		return DotResult.fail(DotError.CODE_STATE, "Effects are not set up.")

	var def := manager.definition(id)
	if def == null:
		return DotResult.fail(DotError.CODE_INVALID, "No effect '%s'." % id)

	var player: G2GPlayer = game.players.get(player_id, null)
	if player == null:
		return DotResult.fail(DotError.CODE_INVALID, "No player '%s'." % player_id)

	if is_movement(def) and _in_ranked_run(player):
		if not allow_movement_during_runs:
			return DotResult.fail(
				DotError.CODE_FORBIDDEN,
				(
					"'%s' changes how %s moves and they are in a ranked run. A style "
					+ "you did not choose is a record you did not set."
				) % [id, player_id]
			)
		# Allowed, and the run stops being comparable with a clean one. dot-timer has
		# had this field since it was written; this is the first caller.
		player.timer.run.tainted = true
		DotLog.info(
			CHANNEL, "a run was tainted by an effect",
			{"player": String(player_id), "effect": String(id)}
		)

	return manager.apply(id, _entity_of(player_id), _entity_of(source))


func remove(id: StringName, player_id: StringName) -> void:
	if manager == null:
		return
	var _res := manager.remove(id, _entity_of(player_id))


func has(id: StringName, player_id: StringName) -> bool:
	return manager != null and manager.has(_entity_of(player_id), id)


func _in_ranked_run(player: G2GPlayer) -> bool:
	if player.timer == null or player.timer.run == null:
		return false
	if not player.timer.run.is_running():
		return false
	# A practised run is already out of the running, so an effect cannot make it worse.
	return not player.timer.run.used_checkpoints


## The combat entity id for a player, or a stable hash when there is no combat layer.
##
## dot-effects keys by int because dot-combat does, and this game keys players by
## StringName. Going through the combat layer when it is there keeps the two id spaces
## agreeing; the hash is for a server with no deathmatch, where nothing else uses the
## number at all.
func _entity_of(player_id: StringName) -> int:
	if player_id == &"":
		return 0
	if game.combat != null:
		var entity := game.combat.entity_for(player_id)
		if entity != 0:
			return entity
	return abs(String(player_id).hash())


func tick(_delta: float) -> void:
	if manager == null:
		return
	manager.advance(game.current_tick())
	_apply_movement()


## Movement effects reach a player through their tunables.
##
## Re-derived from `base_tunables` every tick rather than multiplied in place: scaling
## the live value compounds, and a 0.65 slow becomes 0.0002 in fifty ticks — the player
## stops dead with every number about the effect correct.
func _apply_movement() -> void:
	for id: Variant in game.players.keys():
		var player: G2GPlayer = game.players[id]
		if player.controller == null or player.controller.tunables == null:
			continue
		if player.base_tunables == null:
			continue
		var scale := manager.move_speed_scale(_entity_of(StringName(id)))
		player.controller.tunables.max_speed = player.base_tunables.max_speed * scale


func _on_damaged(entity: int, amount: float, type: StringName, source: int) -> void:
	if game.combat == null or game.combat.manager == null:
		return
	var health := game.combat.manager.health_of(entity)
	if health == null:
		return
	var damage_type := game.combat.manager.damage_type(type)
	if damage_type == null:
		damage_type = DotDamageType.new()
		damage_type.id = type
	var damage := DotDamage.make(source, entity, amount, damage_type)
	damage.tick = game.current_tick()
	var applied := health.apply(damage)
	if applied != null and applied.lethal:
		game.combat.manager.entity_killed.emit(entity, applied)


func on_player_removed(player_id: StringName) -> void:
	if manager != null:
		manager.forget(_entity_of(player_id))


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}


func describe_lines() -> PackedStringArray:
	if manager == null:
		return PackedStringArray(["effects: not set up"])
	return manager.describe_lines()
