class_name G2GProgress
extends Node

## What a player keeps: statistics and achievements, over the runs they actually made.
##
## [b]dot-leaderboard is already here and this does not replace it.[/b] `G2GGame` has
## kept `fastest` and `points` boards since it was written, and a board is one number
## per player ordered. A stat is many numbers per player accumulated, and an achievement
## is a rule over those. The three answer different questions and this node is the two
## that were missing.
##
## [b]Nothing here counts anything twice.[/b] `DotFpsStats` has counted jumps, perfect
## jumps, strafes and top speed on every controller since dot-player-controller was
## written, and dot-timer counts runs and records. This node reads those out and files
## the difference — which is the only way two counters of one thing cannot disagree.
## The one figure it measures itself is distance, because nothing else does.
##
## [codeblock]
## var progress := G2GProgress.new()
## add_child(progress)
## progress.attach(game)
## progress.begin(&"u12", "Someone")
## [/codeblock]

const CHANNEL := "g2g.progress"

signal award_unlocked(player_id: StringName, achievement: DotAchievement)

@export_group("Reporting")

@export var report_to_backbone: bool = false

@export_range(0.0, 600.0, 5.0) var report_interval: float = 30.0

@export_group("Storage")

## Where lifetime achievement progress is kept. Empty keeps it in memory.
@export_dir var progress_dir: String = ""

var stats: DotStatsTracker = null
var achievements: DotAchievementTracker = null
var link: DotAchievementStatsLink = null

var _game: G2GGame = null

## player id -> the movement counters as they were at the last sample.
##
## [b]Held so a DELTA can be filed.[/b] `DotFpsStats` is a running total that is reset
## when a run finishes and is not reset when a player leaves a start zone; filing the
## total on every sample would add the whole history on every sample. Same shape as
## `DotAchievementStatsLink`'s baselines, one layer down, and for the same reason.
var _movement_baseline: Dictionary = {}

## player id -> where they were at the last sample, for the distance counter.
var _last_position: Dictionary = {}

## player id -> seconds of playtime not yet filed as a whole second.
var _playtime: Dictionary = {}

var _attached: bool = false


func attach(game: G2GGame) -> DotResult:
	if _attached:
		return DotResult.fail(DotError.CODE_STATE, "Already attached.")

	if game == null or game.timers == null:
		return DotResult.fail(
			DotError.CODE_STATE, "Progress needs a game with a timer manager."
		)

	_game = game

	var built := _build()

	if not built.ok:
		return built

	game.timers.player_started.connect(_on_started)
	game.timers.player_finished.connect(_on_finished)
	game.timers.record_accepted.connect(_on_record)
	game.map_ready.connect(_on_map_ready)
	game.player_removed.connect(_on_player_removed)

	_attached = true
	return DotResult.success(self)


func _build() -> DotResult:
	stats = DotStatsTracker.new()
	stats.name = "Stats"
	stats.schema = G2GStats.schema()
	stats.report_to_backbone = report_to_backbone
	stats.report_interval = report_interval
	stats.define_on_start = report_to_backbone
	add_child(stats)

	var stats_started := stats.start()

	if not stats_started.ok:
		return stats_started.wrap("The g2gfast stats tracker could not start")

	achievements = DotAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = G2GAwards.catalogue()
	achievements.report_to_backbone = report_to_backbone
	achievements.autosave_interval = report_interval
	achievements.register_as = DotAchievementTracker.SERVICE

	if progress_dir != "":
		var file_store := DotAchievementStoreFile.new()
		file_store.directory = progress_dir
		achievements.store = file_store
	else:
		achievements.store = DotAchievementStoreMemory.new()

	add_child(achievements)

	var awards_started := achievements.start()

	if not awards_started.ok:
		return awards_started.wrap("The g2gfast achievement tracker could not start")

	achievements.unlocked.connect(
		func(player: String, achievement: DotAchievement) -> void:
			award_unlocked.emit(StringName(player), achievement)
	)

	# The differencer between a session total and a lifetime total. See
	# `DotAchievementStatsLink` — wiring `recorded` straight into `record` adds the
	# running total to the lifetime total on every reading.
	link = DotAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	link.stats = stats
	add_child(link)

	var linked := link.start()

	if not linked.ok:
		return linked.wrap("The stats-to-achievements link could not start")

	return DotResult.success(null)


# --- Players ---------------------------------------------------------------

## Starts counting for a player.
##
## A coroutine, because an achievement store may be remote. Dropping the await is
## safe — readings that arrive during the load are still counted, because the link
## holds its baseline until the tracker has the player — but the await on the
## tracker's own call must not be dropped.
func begin(player_id: StringName, display_name: String = "") -> void:
	if not _attached:
		return

	stats.begin(player_id, display_name)

	_movement_baseline[player_id] = {}
	_playtime[player_id] = 0.0
	_last_position.erase(player_id)

	var began: DotResult = await achievements.begin(String(player_id))

	if not began.ok:
		DotLog.warn(CHANNEL, "achievement progress could not be loaded", {
			"player": String(player_id), "why": began.error.message
		})


## Stops counting and forgets the baselines.
func leave(player_id: StringName) -> void:
	if not _attached:
		return

	_flush_movement(player_id)
	_flush_playtime(player_id, true)

	stats.end(player_id)
	link.forget(String(player_id))

	_movement_baseline.erase(player_id)
	_last_position.erase(player_id)
	_playtime.erase(player_id)

	var ended: DotResult = await achievements.end(String(player_id))

	if not ended.ok:
		DotLog.debug(CHANNEL, "achievement progress could not be saved", {
			"player": String(player_id), "why": ended.error.message
		})


func record(player_id: StringName, stat_id: StringName, value: float = 1.0) -> void:
	if _attached:
		stats.record(player_id, stat_id, value)


func session_values(player_id: StringName) -> DotStatsValues:
	return stats.session_values(player_id) if _attached else DotStatsValues.new()


func points_of(player_id: StringName) -> int:
	return achievements.points_of(String(player_id)) if _attached else 0


# --- Sampling --------------------------------------------------------------

## Reads the movement counters and the distance off every player. Once per tick.
##
## [b]Called from the game's tick, not from a frame.[/b] Every counter here is a
## per-tick measurement — the whole reason a run's time is a tick count — and a
## sampler on the frame clock would count a different number of samples on a client
## rendering at 60 than on a server ticking at 128.
func sample(delta: float) -> void:
	if not _attached or _game == null:
		return

	for id in _game.players.keys():
		var player: G2GPlayer = _game.players[id]

		if player == null or player.controller == null:
			continue

		_sample_movement(id, player)
		_sample_distance(id, player)

		if _playtime.has(id):
			_playtime[id] = float(_playtime[id]) + delta

			if float(_playtime[id]) >= 1.0:
				_flush_playtime(id, false)


## Files the difference in the controller's own counters since the last sample.
##
## [b]The reset is what makes this a difference rather than a total.[/b]
## `G2GGame._on_player_finished` calls `controller.stats.reset()` on every finish, so
## a naive "file the total" would file the whole history on every sample and then
## start again from nothing. A total that went DOWN is a reset, and the whole new
## value is filed rather than a negative one — the same rule
## `DotAchievementStatsLink` applies one layer up, for the same reason.
func _sample_movement(player_id: StringName, player: G2GPlayer) -> void:
	var counters := player.controller.stats
	var held: Dictionary = _movement_baseline.get(player_id, {})

	_file_delta(player_id, held, "jumps", G2GStats.JUMPS, float(counters.jumps))
	_file_delta(
		player_id, held, "perfect", G2GStats.PERFECT_JUMPS,
		float(counters.perfect_jumps)
	)
	_file_delta(player_id, held, "strafes", G2GStats.STRAFES, float(counters.strafes))

	# BEST, not a delta: `record` merges through the stat's own kind, so filing the
	# running maximum leaves the highest one. In units, because everything a player
	# reads in this game is.
	if counters.max_speed > 0.0:
		record(player_id, G2GStats.TOP_SPEED, G2GUnits.to_units(counters.max_speed))

	_movement_baseline[player_id] = held


func _file_delta(
	player_id: StringName,
	held: Dictionary,
	key: String,
	stat: StringName,
	now: float
) -> void:
	var before := float(held.get(key, 0.0))
	var delta := now - before if now >= before else now

	held[key] = now

	if delta > 0.0:
		record(player_id, stat, delta)


## Metres travelled, horizontally.
##
## [b]The one figure this file measures rather than reads.[/b] Nothing else counts it,
## and it is horizontal because a surf descent would otherwise credit a player for
## falling — which is the opposite of what a distance stat is for on a movement server.
##
## A teleport is not travel: a jump of more than the map's own scale in one tick is a
## respawn, a stage warp or a `!r`, and counting it would let a player farm distance
## by pressing a key.
func _sample_distance(player_id: StringName, player: G2GPlayer) -> void:
	var at := player.controller.state.position

	if not _last_position.has(player_id):
		_last_position[player_id] = at
		return

	var before: Vector3 = _last_position[player_id]
	_last_position[player_id] = at

	var moved := Vector2(at.x - before.x, at.z - before.z).length()

	# Half a metre in one tick at 128 Hz is 64 m/s, which is well past anything the
	# movement can produce and well short of a map's width.
	if moved > 0.0 and moved < 0.5:
		record(player_id, G2GStats.DISTANCE, moved)


func _flush_movement(player_id: StringName) -> void:
	if not _movement_baseline.has(player_id) or _game == null:
		return

	var player: G2GPlayer = _game.players.get(player_id)

	if player != null and player.controller != null:
		_sample_movement(player_id, player)


func _flush_playtime(player_id: StringName, all_of_it: bool) -> void:
	var held := float(_playtime.get(player_id, 0.0))

	if held <= 0.0:
		return

	var whole := roundf(held) if all_of_it else floorf(held)

	if whole <= 0.0:
		return

	record(player_id, G2GStats.PLAYTIME_SEC, whole)
	_playtime[player_id] = held - whole


# --- Events ----------------------------------------------------------------

func _on_started(player_id: StringName, _run: DotTimerRun) -> void:
	record(player_id, G2GStats.RUNS_STARTED)


func _on_finished(player_id: StringName, run: DotTimerRun) -> void:
	record(player_id, G2GStats.RUNS_FINISHED)
	record(player_id, G2GStats.RUN_SECONDS, run.time())

	# LOWEST. `merge` takes the incoming value whole when there is nothing held, which
	# is the distinction between "held zero" and "never seen" — without it every
	# player's best time would be zero the moment the feature shipped.
	record(player_id, G2GStats.BEST_TIME, run.time())


## A record was accepted. Rank 1 is the server record.
func _on_record(
	record_row: DotTimerRecord, _previous: DotTimerRecord, rank: int
) -> void:
	record(record_row.player_id, G2GStats.RECORDS_SET)

	if rank == 1:
		record(record_row.player_id, G2GStats.WORLD_RECORDS)


## The map changed. Everybody present played it.
##
## Counted here rather than on join, because "maps played" is about maps rather than
## about visits: a player who connects during one map and stays for six has played
## six, and one who joins and leaves on the same map has played one.
func _on_map_ready(_map: DotMapDef) -> void:
	for id in _playtime.keys():
		record(id, G2GStats.MAPS_PLAYED)


func _on_player_removed(player_id: StringName) -> void:
	if _playtime.has(player_id):
		leave(player_id)


func describe() -> Dictionary:
	return {
		"attached": _attached,
		"tracking": _playtime.size(),
		"stats": stats.describe() if stats != null else {},
		"achievements": achievements.describe() if achievements != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("progress     %d tracked" % _playtime.size())

	if stats != null:
		out.append_array(stats.describe_lines())

	if achievements != null:
		out.append_array(achievements.describe_lines())

	return out
