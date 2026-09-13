extends Node

## Peer-to-peer, and the one game in this family that refuses to file anything from it.
##
## [b]This is the sharpest disagreement the five games have about one addon, and it is the
## same sentence every other decision in this project comes from: a player who came to run
## must not be stopped by anything added for a player who came to do something else.[/b]
##
## A peer-to-peer host is a player's own machine. It holds the tick rate, the zone
## crossings, the sub-tick fractions and the map — which between them **are** a time. A
## host who wanted to could file a world record by editing a number, and nothing on the
## receiving end could tell.
##
## Three games in this family take dot-peer-to-peer and answer differently:
##
## - **game-simple-lobby** hosts authoritatively, because there is nothing to cheat at.
## - **game-arena** and **game-hungario** sandbox it: play, file nothing.
## - **This one does both halves of that and adds a third**: a run made in a
##   peer-to-peer session is [b]tainted[/b] the moment it starts, using the field dot-timer
##   has had since it was written and which `G2GEffects` was the first caller of.
##
## The taint rather than a refusal is deliberate and is the same choice this game already
## made about movement effects: **a run you cannot compare is still a run worth doing.**
## Practising a map with a friend on a machine neither of you pays for is exactly what
## peer-to-peer is good at; what it is not is a leaderboard.

const CHANNEL := "g2g.party"

signal open(code: String)
signal closed(res: DotResult)

var session: DotP2PSession = null

@export var signalling_url: String = ""

var _http: DotHttp = null


func setup() -> DotResult:
	session = DotP2PSession.new()
	session.name = "P2P"
	session.config = _config()
	add_child(session)

	var res := session.setup()
	if not res.ok:
		return res.wrap("g2gfast's party session")

	session.signaller = _make_signaller()
	session.ended.connect(func(r: DotResult) -> void: closed.emit(r))
	return DotResult.success(null)


func _config() -> DotP2PConfig:
	var c := DotP2PConfig.new()
	# Small. A surf map is a queue of one at a time in practice, and the wire cost of a
	# runner is one movement state.
	c.max_peers = 8
	c.trust = DotP2PConfig.Trust.SANDBOXED
	# Off. A host leaving mid-run is a run that ends; handing the timer to somebody else
	# mid-run would produce a time made of two machines' clocks, which is worse than no
	# time at all.
	c.migrate_host = false
	c.signalling_url = signalling_url
	return c


func _make_signaller() -> DotP2PSignaller:
	if signalling_url.is_empty():
		return DotP2PSignallerLoopback.new(session.local_id)
	_http = DotHttp.new()
	_http.name = "PartyHttp"
	add_child(_http)
	return DotP2PSignallerHttp.new(signalling_url, session.local_id, _http)


func host(display_name: String) -> DotResult:
	if not DotP2PSession.available():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"this build cannot host a practice session",
			DotP2PSession.unavailable_reason()
		)
	var res := session.host(display_name)
	if res.ok:
		open.emit(str(res.value))
		# Said once, plainly, at the moment somebody could still choose otherwise. A
		# player who finds out their session's times did not count *after* setting one is
		# a player who has lost an evening.
		DotLog.info(
			CHANNEL,
			"a practice session is open. Runs made in it are tainted and are not records.",
			{"code": str(res.value)}
		)
	return res


func join(code: String, display_name: String) -> DotResult:
	return session.join(code, display_name)


func leave() -> void:
	session.leave()


func active() -> bool:
	return session != null and session.state() != &"idle"


## Whether a run made now could ever be a record.
func ranked() -> bool:
	return not active()


## Taints a run that is starting, when this session is one nobody can vouch for.
##
## [b]Called at the START of a run rather than at the end, and that is the whole point.[/b]
## A run tainted on finishing is one a player made believing it counted. `DotTimerRun.tainted`
## is the field, `G2GEffects` was its first caller, and this is the second — both for the
## same reason: *a style you did not choose is a record you did not set*, and a host you
## cannot vouch for is the same sentence about the machine instead of about the movement.
##
## Returns true when it tainted something, so a caller can say so on screen.
func taint_if_unranked(run: Object) -> bool:
	if ranked() or run == null:
		return false
	if not (run is DotTimerRun):
		return false
	(run as DotTimerRun).tainted = true
	DotLog.info(CHANNEL, "a run was tainted: this is a peer-to-peer session")
	return true


func describe_lines() -> PackedStringArray:
	if session == null:
		return PackedStringArray(["no party"])
	var out := session.describe_lines()
	out.append(
		"  runs %s" % ("count" if ranked() else "are tainted: nobody can vouch for this host")
	)
	return out
