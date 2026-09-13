extends RefCounted

## Every per-player number a timer server counts, declared in one place.
##
## [b]The ids are the contract, three ways.[/b] The same strings name a stat in
## [DotStatsSchema], a requirement in [G2GAwards]' achievement rules, and a source in
## [G2GProgress]. Three subsystems that never import each other agree because they all
## read the constants below.
##
## [b]Everything countable here is already measured by something else, and none of it
## is measured twice.[/b] `DotFpsStats` counts jumps, perfect jumps, strafes and sync
## on every controller in the game — the movement addon has done it since it was
## written — and dot-timer counts runs and finishes. This file does not re-derive any
## of them; [G2GProgress] reads them out and files deltas, which is the only way two
## counters of one thing cannot disagree.
##
## [b]A time is a LOWEST stat, and getting that wrong is a personal best of zero.[/b]
## [constant DotStatsDef.Kind.LOWEST] keeps the smaller of two readings, and dot-stats'
## `merge` takes the incoming value whole when there is nothing held — which is the
## distinction between "held zero" and "never seen" that makes a first reading of 12
## seconds be 12 rather than min(12, 0).

const CHANNEL := "g2g.stats"

# --- Runs ------------------------------------------------------------------

const RUNS_STARTED := &"g2g.runs_started"
const RUNS_FINISHED := &"g2g.runs_finished"
const RECORDS_SET := &"g2g.records_set"
const WORLD_RECORDS := &"g2g.world_records"

## Fastest run this player has ever filed here, in seconds. LOWEST.
const BEST_TIME := &"g2g.best_time"

## Total seconds spent inside a run. Not the same as time on the server.
const RUN_SECONDS := &"g2g.run_seconds"

# --- Movement --------------------------------------------------------------

const JUMPS := &"g2g.jumps"
const PERFECT_JUMPS := &"g2g.perfect_jumps"
const STRAFES := &"g2g.strafes"

## Fastest horizontal speed ever reached, in genre units per second. BEST.
##
## [b]In units, not metres.[/b] Everything an operator or a player reads in this game
## is in the genre's units — that is Decision 1 — and a stat is read by a player on a
## website. The conversion happens where every other one does.
const TOP_SPEED := &"g2g.top_speed"

## Metres travelled. The one figure kept in metres, because it is not a genre number
## and nobody quotes a distance in units.
const DISTANCE := &"g2g.distance"

# --- The server ------------------------------------------------------------

const PLAYTIME_SEC := &"g2g.playtime_sec"
const MAPS_PLAYED := &"g2g.maps_played"

# --- Deathmatch ------------------------------------------------------------

const KILLS := &"g2g.kills"
const DEATHS := &"g2g.deaths"

# --- The sandbox half ------------------------------------------------------

const HUNTERS_KILLED := &"g2g.hunters_killed"
const PROPS_SPAWNED := &"g2g.props_spawned"


static func ids() -> Array[StringName]:
	return [
		RUNS_STARTED, RUNS_FINISHED, RECORDS_SET, WORLD_RECORDS,
		BEST_TIME, RUN_SECONDS,
		JUMPS, PERFECT_JUMPS, STRAFES, TOP_SPEED, DISTANCE,
		PLAYTIME_SEC, MAPS_PLAYED,
		KILLS, DEATHS,
		HUNTERS_KILLED, PROPS_SPAWNED,
	]


static func schema() -> DotStatsSchema:
	var schema := DotStatsSchema.new()

	_counter(schema, RUNS_STARTED, "Runs started", "runs", false)
	_counter(schema, RUNS_FINISHED, "Runs finished", "runs", true)
	_counter(schema, RECORDS_SET, "Personal bests", "records", true)
	_counter(schema, WORLD_RECORDS, "Server records", "records", true)

	var best := DotStatsDef.make(BEST_TIME, DotStatsDef.Kind.LOWEST, "Best time")
	best.unit = "s"
	best.decimals = 3
	best.publish = true
	schema.stats.append(best)

	_counter(schema, RUN_SECONDS, "Time in runs", "s", false)

	_counter(schema, JUMPS, "Jumps", "jumps", true)
	_counter(schema, PERFECT_JUMPS, "Perfect jumps", "jumps", true)
	_counter(schema, STRAFES, "Strafes", "strafes", false)

	var top := DotStatsDef.make(TOP_SPEED, DotStatsDef.Kind.BEST, "Top speed")
	top.unit = "u/s"
	top.decimals = 0
	top.publish = true
	schema.stats.append(top)

	var distance := DotStatsDef.make(DISTANCE, DotStatsDef.Kind.COUNTER, "Distance")
	distance.unit = "m"
	distance.decimals = 0
	distance.publish = true
	schema.stats.append(distance)

	var time := DotStatsDef.make(PLAYTIME_SEC, DotStatsDef.Kind.COUNTER, "Time played")
	time.unit = "s"
	time.publish = true
	schema.stats.append(time)

	_counter(schema, MAPS_PLAYED, "Maps played", "maps", false)

	_counter(schema, KILLS, "Kills", "kills", true)
	_counter(schema, DEATHS, "Deaths", "deaths", false)

	_counter(schema, HUNTERS_KILLED, "Hunters killed", "kills", true)
	_counter(schema, PROPS_SPAWNED, "Props placed", "props", false)

	return schema


## Perfect-jump ratio from a values bag, as a fraction. Never a division by zero.
##
## Derived, never stored, for [G2GStats]' own reason: a stored quotient is a third
## number that can disagree with the two it came from. It is also the one figure a bhop
## player actually judges themselves on.
static func perfect_ratio_of(values: DotStatsValues) -> float:
	var jumps := values.get_value(JUMPS, 0.0)

	if jumps <= 0.0:
		return 0.0

	return clampf(values.get_value(PERFECT_JUMPS, 0.0) / jumps, 0.0, 1.0)


## Finish rate: how many started runs were finished.
static func finish_rate_of(values: DotStatsValues) -> float:
	var started := values.get_value(RUNS_STARTED, 0.0)

	if started <= 0.0:
		return 0.0

	return clampf(values.get_value(RUNS_FINISHED, 0.0) / started, 0.0, 1.0)


static func _counter(
	schema: DotStatsSchema,
	id: StringName,
	display: String,
	unit: String,
	publish: bool
) -> void:
	var def := DotStatsDef.make(id, DotStatsDef.Kind.COUNTER, display)
	def.unit = unit
	def.publish = publish
	schema.stats.append(def)
