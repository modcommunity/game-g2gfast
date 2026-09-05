class_name G2GQuery
extends DotQueryProvider

## What this server tells a server browser, beyond the fields A2S has room for.
##
## Runs on the query path, which anybody with the address can reach: nothing here
## names a session, a peer or an account. The ghost counts as a bot, because it is
## one — a server browser showing "3/16" for one player and two ghosts is lying.

var game: G2GGame = null
var bridge: G2GNetBridge = null


func _provider_name() -> String:
	return "g2gfast"


func _contribute(snapshot: DotQuerySnapshot) -> void:
	if game == null:
		return

	var bots := 0
	var running := 0
	for id in game.players:
		var player: G2GPlayer = game.players[id]
		if player.replay != null:
			bots += 1
		elif bridge != null and bridge.peer_for_player(G2GNetBridge.session_of(id)) == 0:
			bots += 1
		if player.timer != null and player.timer.run.is_running():
			running += 1

	snapshot.info["bots"] = bots

	var styles := PackedStringArray()
	for style in game.timers.styles_in_order():
		styles.append(String(style.id))

	var out := {
		"tick_rate": game.tick_rate,
		"auto_bhop": game.config.auto_bhop,
		"styles": styles,
		"running": running,
	}

	var map := game.maps.current
	if map != null:
		out["map"] = String(map.id)
		out["tracks"] = Array(game.timers.zones.playable_tracks()) if game.timers.zones != null else []
		var wr := game.replays.best(map.id, DotTimerTrack.MAIN, &"normal")
		if wr != null:
			out["wr"] = {"time": wr.time, "by": wr.player_name}

	snapshot.contribute_game(out)
