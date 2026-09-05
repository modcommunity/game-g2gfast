class_name G2GReplays
extends RefCounted

## The best replay per map, track and style — what the world-record ghost plays.
##
## dot-timer records a replay of every run and hands the finished one over with the
## record; it deliberately does not keep them (its CLAUDE.md: what to draw at a replay
## is a game's decision). This keeps one per key: the fastest, in memory always and on
## disk when there is a records directory, as the bytes [DotTimerReplay] itself writes,
## so a replay set at 64 Hz plays back on a 128 Hz server without anybody converting it.
##
## [b]A replay is kept only when the record it belongs to was accepted[/b], not when a
## run was merely faster: a tainted or a checkpoint-assisted run is not a record and
## must not become the ghost everybody chases.

const CHANNEL := "g2g.replays"
const SUFFIX := ".replay"

## Empty for memory only.
var directory: String = ""

var _best: Dictionary = {}


func setup(p_directory: String) -> DotResult:
	directory = p_directory
	if directory == "":
		return DotResult.success(self)
	var made := DirAccess.make_dir_recursive_absolute(_replay_dir())
	if made != OK:
		return DotResult.fail(
			DotError.CODE_IO, "Could not create the replays directory.", _replay_dir()
		)
	return DotResult.success(self)


static func key_for(map_id: StringName, track: int, style_id: StringName) -> String:
	return "%s/%d/%s" % [String(map_id), track, String(style_id)]


## Offers a replay of an accepted record. Kept if it is the first or the fastest.
func offer(replay: DotTimerReplay, record: DotTimerRecord) -> bool:
	if replay == null or record == null or replay.frames.is_empty():
		return false

	var key := key_for(record.map_id, record.track, record.style_id)
	var current: DotTimerReplay = best(record.map_id, record.track, record.style_id)
	if current != null and current.time <= record.time:
		return false

	replay.map_id = record.map_id
	replay.track = record.track
	replay.style_id = record.style_id
	replay.player_name = record.player_name
	replay.time = record.time
	_best[key] = replay

	if directory != "":
		var saved := replay.save(_path_for(record.map_id, record.track, record.style_id))
		if not saved.ok:
			DotLog.warn(CHANNEL, "could not write a replay", {"why": saved.error.message})

	return true


## The best replay for a key, from memory, or from disk the first time.
func best(map_id: StringName, track: int, style_id: StringName) -> DotTimerReplay:
	var key := key_for(map_id, track, style_id)
	if _best.has(key):
		return _best[key]
	if directory == "":
		return null

	var path := _path_for(map_id, track, style_id)
	if not FileAccess.file_exists(path):
		return null

	var parsed := DotTimerReplay.load_from(path)
	if not parsed.ok:
		DotLog.warn(CHANNEL, "a stored replay did not parse", {
			"path": path, "why": parsed.error.message
		})
		return null

	_best[key] = parsed.value
	return parsed.value


func forget_all() -> void:
	_best.clear()


func _replay_dir() -> String:
	return directory.path_join("replays")


func _path_for(map_id: StringName, track: int, style_id: StringName) -> String:
	return _replay_dir().path_join(
		"%s__%d__%s%s" % [_safe(String(map_id)), track, _safe(String(style_id)), SUFFIX]
	)


## A file name from an id. Same rule as dot-timer's records store: keep what is
## safe, replace the rest, and append a hash when anything was replaced so two ids
## that differ only in the replaced characters do not share a file.
static func _safe(text: String) -> String:
	const SAFE := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
	var out := ""
	var replaced := false
	for c in text:
		if SAFE.contains(c):
			out += c
		else:
			out += "_"
			replaced = true
	if replaced or out == "":
		out += "-" + String.num_uint64(text.hash())
	return out


func describe() -> Dictionary:
	var kept := {}
	for key in _best:
		var replay: DotTimerReplay = _best[key]
		kept[key] = {"by": replay.player_name, "time": replay.time, "frames": replay.frames.size()}
	return {"directory": directory, "kept": kept}
