class_name G2GEvents
extends RefCounted

## The wire format for everything that is not a snapshot or an input.
##
## Encoders and decoders in pairs, because they have to be exact inverses and nothing
## checks that for you — the headless net suite round-trips each of them.
##
## [b]Movement travels as the CONFIG, not as the tunables.[/b] A client rebuilds its
## tunables from the same [G2GConfig] fields through the same [G2GMovement] the server
## used, so the two derive bit-identical values — which is what prediction needs. A
## fingerprint rides with it so a mismatch is one log line rather than a week of "the
## netcode feels bad".

enum Kind {
	## Tick rate, who you are, the map, the movement, the server tick.
	HELLO,
	## A player joined, or changed: name, peer, net id, avatar, style, track.
	JOIN,
	LEAVE,
	## The movement changed under everybody. Carries the config fields.
	MOVEMENT,
	## The map changed. Clients load it from their own build.
	MAP,
	## A player's run state changed: started, stopped, paused. A DotTimerNet.RunState.
	TIMER,
	## A player finished. A DotTimerNet.Finish plus the rank.
	FINISH,
	## Somebody set a record worth announcing.
	RECORD,
	## Text for everyone: a stage split, a refusal, a vote result.
	NOTICE,
}

enum Ask {
	## I have loaded and can receive. Tell me everything.
	READY,
	## Put me on this style (index into the server's ordered table).
	STYLE,
	## Put me on this track.
	TRACK,
	## Here is my avatar.
	AVATAR,
	## Put me back at the start.
	RESTART,
	## Rock the vote.
	RTV,
	## Save a checkpoint (0), teleport to it (1), clear them (2).
	CHECKPOINT,
}

const NAME_BYTES := 64
const MAP_BYTES := 64
const AVATAR_BYTES := 4096
const TEXT_BYTES := 256


static func kind_name(kind: int) -> String:
	var names := Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?"


static func _w() -> DotNetWriter:
	return DotNetWriter.new()


# --- Movement --------------------------------------------------------------

## The G2GConfig fields the simulation reads. Everything else stays server-side.
static func write_movement(config: G2GConfig) -> PackedByteArray:
	# Snapped first, so the fingerprint is of what the receiver will read: a
	# double that does not survive float32 would otherwise fingerprint differently
	# on the two ends while every visible value agreed.
	config.snap_movement()
	var writer := _w()
	for field in G2GConfig.MOVEMENT_FIELDS:
		var value: Variant = config.get(field)
		if value is bool:
			writer.write_bool(value)
		else:
			writer.write_float32(float(value))
	writer.write_string(G2GMovement.tunables_for(config).fingerprint(), 32)
	return writer.to_bytes()


## Applies a MOVEMENT body to a config. Returns the server's fingerprint.
static func read_movement(reader: DotNetReader, config: G2GConfig) -> String:
	for field in G2GConfig.MOVEMENT_FIELDS:
		var current: Variant = config.get(field)
		if current is bool:
			config.set(field, reader.read_bool())
		else:
			config.set(field, reader.read_float32())
	return reader.read_string(32)


# --- HELLO -----------------------------------------------------------------

static func write_hello(
	tick_rate: int, player_id: int, peer_id: int, server_tick: int,
	map_id: StringName, config: G2GConfig
) -> PackedByteArray:
	var writer := _w()
	writer.write_uint(tick_rate, 8)
	writer.write_varint(player_id)
	writer.write_varint(peer_id)
	writer.write_uint(server_tick, 32)
	writer.write_string(String(map_id), MAP_BYTES)
	writer.write_bytes(write_movement(config))
	return writer.to_bytes()


static func read_hello(reader: DotNetReader) -> Dictionary:
	var out := {
		"tick_rate": reader.read_uint(8),
		"player_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"server_tick": reader.read_uint(32),
		"map_id": StringName(reader.read_string(MAP_BYTES)),
		"movement": reader.read_bytes(1024),
	}
	out["ok"] = reader.ok()
	return out


# --- JOIN / LEAVE ----------------------------------------------------------

static func write_join(
	player_id: int, peer_id: int, net_id: int, display_name: String,
	avatar: DotAvatar, style_index: int, track: int
) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(player_id)
	writer.write_varint(peer_id)
	writer.write_varint(net_id)
	writer.write_string(display_name, NAME_BYTES)
	writer.write_uint(style_index, DotTimerNet.STYLE_BITS)
	writer.write_uint(track, DotTimerTrack.BITS)
	var text := JSON.stringify(avatar.to_dict()) if avatar != null else ""
	writer.write_string(text, AVATAR_BYTES)
	return writer.to_bytes()


static func read_join(reader: DotNetReader) -> Dictionary:
	var out := {
		"player_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"net_id": reader.read_varint(),
		"name": reader.read_string(NAME_BYTES),
		"style_index": reader.read_uint(DotTimerNet.STYLE_BITS),
		"track": reader.read_uint(DotTimerTrack.BITS),
	}
	var text := reader.read_string(AVATAR_BYTES)
	out["avatar"] = null
	if text != "":
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			var built := DotAvatar.from_dict(parsed)
			if built.ok:
				out["avatar"] = built.value
	out["ok"] = reader.ok()
	return out


static func write_player(player_id: int) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(player_id)
	return writer.to_bytes()


static func read_player(reader: DotNetReader) -> int:
	return reader.read_varint()


# --- MAP -------------------------------------------------------------------

static func write_map(map_id: StringName) -> PackedByteArray:
	var writer := _w()
	writer.write_string(String(map_id), MAP_BYTES)
	return writer.to_bytes()


static func read_map(reader: DotNetReader) -> StringName:
	return StringName(reader.read_string(MAP_BYTES))


# --- TIMER / FINISH --------------------------------------------------------

static func write_timer(player_id: int, state: DotTimerNet.RunState) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(player_id)
	state.write(writer)
	return writer.to_bytes()


static func read_timer(reader: DotNetReader) -> Dictionary:
	var player_id := reader.read_varint()
	var state := DotTimerNet.RunState.new()
	state.read(reader)
	return {"player_id": player_id, "state": state, "ok": reader.ok()}


static func write_finish(player_id: int, finish: DotTimerNet.Finish) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(player_id)
	finish.write(writer)
	return writer.to_bytes()


static func read_finish(reader: DotNetReader) -> Dictionary:
	var player_id := reader.read_varint()
	var finish := DotTimerNet.Finish.new()
	finish.read(reader)
	return {"player_id": player_id, "finish": finish, "ok": reader.ok()}


# --- NOTICE / RECORD -------------------------------------------------------

static func write_text(player_id: int, text: String) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(player_id)
	writer.write_string(text, TEXT_BYTES)
	return writer.to_bytes()


static func read_text(reader: DotNetReader) -> Dictionary:
	return {"player_id": reader.read_varint(), "text": reader.read_string(TEXT_BYTES)}


# --- Requests --------------------------------------------------------------

static func write_int(value: int) -> PackedByteArray:
	var writer := _w()
	writer.write_varint(maxi(value, 0))
	return writer.to_bytes()


static func read_int(reader: DotNetReader) -> int:
	return reader.read_varint()


static func write_avatar(avatar: DotAvatar) -> PackedByteArray:
	var writer := _w()
	writer.write_string(JSON.stringify(avatar.to_dict()) if avatar != null else "", AVATAR_BYTES)
	return writer.to_bytes()


static func read_avatar(reader: DotNetReader) -> DotAvatar:
	var text := reader.read_string(AVATAR_BYTES)
	if text == "":
		return null
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return null
	var built := DotAvatar.from_dict(parsed)
	return built.value if built.ok else null
