class_name G2GArsenal
extends RefCounted

## The weapons, items and damage a deathmatch server runs with.
##
## [b]Why a timer game has combat at all.[/b] Not as a second game bolted on: surf and
## bhop communities have run deathmatch on their own maps for twenty years — `surf_`
## maps with a DM plugin are a whole genre of server, and the reason is that a map
## whose movement everybody has learned is a map where a fight is about movement. What
## makes it work is that the weapons are the genre's, not an arena shooter's: a
## one-shot pistol and a knife, hitscan, no reload, no ammunition to think about, so
## nothing takes your hands off the strafe keys.
##
## [b]It is off by default and it is a mode, not a setting on top of the timer.[/b]
## `sv_deathmatch` turns it on; while it is on the timer still runs, because a player
## who wants to run should not be stopped from running by a player who wants to shoot.
## What changes is that everybody is shootable and a [DotMatch] is counting.
##
## Two weapons rather than four, and the difference is the whole design:
##
## [codeblock]
## deagle   one shot, one kill at any range you can hit at. Slow.
## knife    instant, silent, and only if you got there.
## [/codeblock]

const DAMAGE_BULLET := &"bullet"
const DAMAGE_BLADE := &"blade"
const DAMAGE_FALL := &"fall"
const DAMAGE_WORLD := &"world"

const ITEM_DEAGLE := &"deagle"
const ITEM_KNIFE := &"knife"


# --- Damage types ----------------------------------------------------------

static func bullet() -> DotDamageType:
	var type := DotDamageType.make(DAMAGE_BULLET, "Bullet")
	type.armour_share = 0.5
	type.armour_wear = 1.0
	# No falloff. A one-shot pistol whose damage decays is a one-shot pistol at close
	# range and a nuisance everywhere else, which makes the fight about closing rather
	# than about aiming — and closing is what the movement is for, so the interesting
	# version is the one where a player who can aim across the map may.
	type.falloff_start = 0.0
	type.falloff_end = 0.0
	type.self_scale = 0.0
	return type


static func blade() -> DotDamageType:
	var type := DotDamageType.make(DAMAGE_BLADE, "Knife")
	# Armour does not stop a knife. It is the reward for having got there.
	type.armour_share = 0.0
	type.uses_hit_groups = false
	type.self_scale = 0.0
	return type


static func fall() -> DotDamageType:
	var type := DotDamageType.make(DAMAGE_FALL, "Fall")
	type.armour_share = 0.0
	type.uses_hit_groups = false
	type.self_scale = 1.0
	return type


static func world() -> DotDamageType:
	var type := DotDamageType.make(DAMAGE_WORLD, "The world")
	type.armour_share = 0.0
	type.uses_hit_groups = false
	return type


static func damage_types() -> Array[DotDamageType]:
	return [bullet(), blade(), fall(), world()]


# --- Weapons ---------------------------------------------------------------

## One shot, one kill on a headshot and two on a body. Slow enough to miss with.
##
## [b]No magazine and no reload, deliberately.[/b] Reloading takes a hand off the
## strafe keys, and every second a player spends not strafing on a surf map is a second
## they spend falling. The rate of fire is the cost instead.
static func deagle() -> DotWeapon:
	var weapon := DotWeapon.make(ITEM_DEAGLE, 62.0)
	weapon.display_name = "Deagle"
	weapon.slot = 2
	weapon.fire_mode = DotWeapon.Fire.SEMI
	weapon.rpm = 160.0
	weapon.magazine = 0
	weapon.infinite_reserve = true
	# Wide when moving and tight when still, which on a movement server is the whole
	# trade: the fastest player on the map is the hardest to hit and the worst shot.
	weapon.spread_degrees = 0.25
	weapon.spread_moving = 5.5
	weapon.spread_airborne = 8.0
	weapon.spread_crouched = 0.15
	weapon.spread_bloom = 1.2
	weapon.spread_bloom_max = 6.0
	weapon.spread_recovery = 6.0
	weapon.recoil_pitch = 2.4
	weapon.max_range = 400.0
	weapon.deploy_sec = 0.25
	weapon.holster_sec = 0.2
	weapon.damage_type = bullet()
	return weapon


## Instant, and only if you got there.
static func knife() -> DotWeapon:
	var weapon := DotWeapon.make(ITEM_KNIFE, 120.0)
	weapon.display_name = "Knife"
	weapon.slot = 1
	weapon.fire_mode = DotWeapon.Fire.SEMI
	weapon.rpm = 90.0
	weapon.magazine = 0
	weapon.infinite_reserve = true
	weapon.spread_degrees = 0.0
	# Two metres. A knife that reaches further than an arm is a hitscan weapon with a
	# short range, which is a different and much worse thing to fight.
	weapon.max_range = 2.0
	weapon.deploy_sec = 0.15
	weapon.holster_sec = 0.1
	weapon.damage_type = blade()
	return weapon


static func weapons() -> Array[DotWeapon]:
	return [knife(), deagle()]


static func weapon_table() -> Dictionary:
	var table := {}

	for weapon in weapons():
		table[weapon.id] = weapon

	return table


# --- Loadout ---------------------------------------------------------------

static func catalogue() -> DotItemCatalogue:
	var items: Array[DotItem] = []

	for weapon in weapons():
		var item := DotItem.make(weapon.id, DotItem.KIND_WEAPON, true)
		item.display_name = weapon.display_name
		item.cost = 1
		items.append(item)

	return DotItemCatalogue.of(items)


## Two slots, both filled, nothing to choose.
##
## [b]A loadout schema with no choice in it is not a pointless one.[/b] It is what
## makes the deathmatch half go through the same door every other game in this family
## does — a document a server validates against entitlements without loading a mesh —
## so the day this server sells a knife skin, the plumbing is already there and the
## only change is a second item in a slot.
static func loadout_schema() -> DotLoadoutSchema:
	var melee := DotLoadoutSlot.make(&"melee", true, ITEM_KNIFE)
	melee.display_name = "Melee"
	melee.kinds = [DotItem.KIND_WEAPON]
	melee.arsenal_slot = 1
	melee.order = 10

	var sidearm := DotLoadoutSlot.make(&"sidearm", true, ITEM_DEAGLE)
	sidearm.display_name = "Sidearm"
	sidearm.kinds = [DotItem.KIND_WEAPON]
	sidearm.arsenal_slot = 2
	sidearm.order = 20

	var schema := DotLoadoutSchema.of(&"g2g", [melee, sidearm], catalogue())
	schema.point_budget = 4
	return schema


## The match rules a movement deathmatch runs on.
##
## Free-for-all, no rounds, no warmup worth the name. A round-based deathmatch on a
## timer server would stop everybody who came to run, and stopping them is the one
## thing this half must never do.
static func match_rules(limit: int = 40) -> DotMatchRules:
	var rules := DotMatchRules.deathmatch(limit)
	rules.display_name = "Deathmatch"
	# Fast. The map is the point and dying is a detour.
	rules.respawn_delay_sec = 1.0
	rules.spawn_protection_sec = 2.0
	rules.warmup_sec = 0.0
	rules.countdown_sec = 0.0
	rules.min_players = 2
	rules.intermission_sec = 5.0
	rules.match_end_sec = 10.0
	rules.suicide_points = -1
	# No time limit: the MAP's clock ends the map, and a second clock underneath it
	# that ends the match is two authorities over one question. dot-vote's director
	# already owns "how long does this map get".
	rules.time_limit_sec = 0.0
	return rules
