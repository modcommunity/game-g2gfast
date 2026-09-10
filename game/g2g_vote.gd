class_name G2GVote
extends Node

## What plays next, decided by the players, with the genre's own rules.
##
## [b]This game already had a rock-the-vote and it was not one.[/b]
## `G2GGame.rock_the_vote` forwards to [DotMapTimeLimit], which counts rtv votes
## against a fraction and expires the map — a countdown and a tally and nothing else.
## What a records community actually runs is a ballot: nominations with caps,
## seconding, an instant runoff so a six-option vote is not won by a fifth of the
## server, a cooldown so `bhop_g2g_intro` does not come round twice in three maps, and
## an extend option so a map nobody has finished yet is not cut off.
##
## dot-vote is fifty-five settings' worth of exactly that, and none of it is restated
## here. What this file is, is the four callables that say who the players are, plus
## one rule about who calls [method DotVoteDirector.begin].
##
## [b]`begin_on_apply` is off, and getting it wrong halves every cooldown.[/b] The
## director can announce a change it just made, and so can the host through the map
## session's own `changed` — which is the one that has to be connected, because it also
## fires for an admin typing `g2g_map`. Both firing means two entries in the play
## history for one play, and a "not in the last five maps" cooldown that is quietly two
## or three. dot-vote found that by running inside a real host, which is the only place
## it is visible.
##
## [codeblock]
## var vote := G2GVote.new()
## vote.game = game
## add_child(vote)
## vote.setup()
## vote.announce_fn = func(line: String) -> void: services.announce(line)
## [/codeblock]

const CHANNEL := "g2g.vote"

signal vote_opened(options: Array, seconds: float)
signal vote_closed(result: DotVoteResult)
signal rocked(voter: StringName, votes: int, needed: int)
signal change_due(id: StringName, choice: DotVoteChoice)

@export_group("Wiring")

## Whether this instance applies a result.
##
## Off on a client, which mirrors a vote so it can draw the ballot and must never
## change its own map.
@export var authoritative: bool = true

var game: G2GGame = null

var director: DotVoteDirector = null
var source: DotVoteMapSource = null

var announce_fn: Callable = Callable()
var is_admin_fn: Callable = Callable()


func setup() -> DotResult:
	if game == null or game.maps == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The vote needs a game with a map session."
		)

	# dot-vote's own map source, rather than a subclass. It duck-types the catalogue
	# and the session as [Object]s — which is why dot-vote installs in a project that
	# has never heard of dot-map — and `apply` calls `session.change_to(id)`, which is
	# exactly what an admin's `g2g_map` calls.
	source = DotVoteMapSource.of(game.maps.catalogue, game.maps)

	if not source.is_usable():
		return DotResult.fail(DotError.CODE_STATE, "There is nothing to vote for.")

	director = DotVoteDirector.new()
	director.name = "VoteDirector"
	director.rules = _rules()
	director.source = source
	director.auto_apply = authoritative
	director.begin_on_apply = false
	# The game's tick drives this, not the frame clock: a server that stalls should
	# not lose that time off its map, and a test must be able to run an hour of one in
	# a millisecond.
	director.self_advance = false
	director.register_service = authoritative

	director.player_count_fn = _player_count

	director.voters_fn = func() -> Array:
		var out: Array = []

		for id in _voter_ids():
			out.append(id)

		return out

	director.is_admin_fn = func(voter: StringName) -> bool:
		return is_admin_fn.is_valid() and bool(is_admin_fn.call(voter))

	# The ghost is a player in every sense that matters to the rest of this game — it
	# has an id, a rig and a timer — and in no sense that matters to a vote. Counting
	# it would let a one-player server pass a quorum of two, and let it rock the vote
	# on its own.
	director.is_spectator_fn = func(voter: StringName) -> bool:
		return voter == G2GGame.GHOST_ID

	director.announce_fn = func(line: String) -> void:
		if announce_fn.is_valid():
			announce_fn.call(line)

	add_child(director)

	director.vote_opened.connect(
		func(options: Array, seconds: float) -> void:
			vote_opened.emit(options, seconds)
	)
	director.vote_closed.connect(
		func(result: DotVoteResult) -> void: vote_closed.emit(result)
	)
	director.rocked.connect(
		func(voter: StringName, votes: int, needed: int) -> void:
			rocked.emit(voter, votes, needed)
	)
	director.change_due.connect(
		func(id: StringName, choice: DotVoteChoice) -> void:
			change_due.emit(id, choice)
	)

	# Whatever the server booted on, so the clock starts and the history has an entry.
	game.maps.changed.connect(_on_map_changed)

	if game.maps.current != null:
		director.begin(game.maps.current.id)

	return DotResult.success(self)


## The rules a records server votes by.
##
## [b]Instant runoff, and a per-map time limit.[/b] The second is the one dot-vote
## built [member DotVoteChoice.time_limit_sec] for and it is this genre's own problem:
## forty minutes of `surf_kitsune` and ten minutes of a three-stage bhop intro are not
## the same number, and a server that gives them the same one either rushes the first
## or bores everybody through the second. A map def carries it in `meta.vote`.
func _rules() -> DotVoteRules:
	var rules := DotVoteRules.new()

	rules.trigger = DotVoteRules.Trigger.TIME_LIMIT
	rules.vote_lead_sec = 120.0
	rules.duration_sec = maxf(game.config.map_seconds, 300.0)
	rules.vote_duration_sec = 30.0
	rules.method = DotVoteRules.Method.INSTANT_RUNOFF
	rules.tie_break = DotVoteRules.TieBreak.LEAST_RECENTLY_PLAYED
	rules.max_options = 6

	# Extending matters more here than anywhere else in this family: a player two
	# stages into a run they have been learning for an hour should not lose the map to
	# a clock. Three extends of ten minutes is the ceiling.
	rules.include_extend = true
	rules.extend_seconds = 600.0
	rules.max_extends = 3
	rules.extend_resets_rtv = true

	rules.rtv_enabled = true
	rules.rtv_fraction = 0.6
	rules.rtv_min_players = 2
	# Two minutes, measured from when the map started. Without it a player who does
	# not like the map can rock the vote before anybody has left the start pad.
	rules.rtv_delay_sec = 120.0

	rules.nominations_enabled = true
	rules.nomination_seconding = true
	rules.nomination_slots = 3

	# Immediately. A timer server has no rounds to end on, and "at the end of the
	# round" on a game with none is a change that never happens — which is the shape
	# of every setting this family has found that reads correctly and decides nothing.
	rules.apply = DotVoteRules.Apply.IMMEDIATE
	rules.apply_delay_sec = 5.0

	rules.cooldown = 5
	rules.cooldown_mode = DotVoteRules.Cooldown.PLAYS
	# Capped against the pool, so a five-map cooldown on a three-map catalogue does
	# not leave nothing to offer. dot-vote applies it; naming it here is what makes it
	# a decision rather than a default nobody read.
	rules.cooldown_max_fraction = 0.5

	return rules


## How many players there are, for every threshold in the rules.
##
## [b]Not `game.players.size()`.[/b] That counts the record ghost, which is a
## [G2GPlayer] with a replay and no peer — so on an empty server the rtv fraction
## would be measured against one player who cannot vote, and a quorum of two would be
## reached by nobody.
func _player_count() -> int:
	return _voter_ids().size()


func _voter_ids() -> Array[StringName]:
	var out: Array[StringName] = []

	if game == null:
		return out

	for id in game.players.keys():
		if id == G2GGame.GHOST_ID:
			continue

		out.append(id)

	return out


## Tells the director what is running, after a change from ANY cause.
##
## The one call site. See the class note on `begin_on_apply`.
func _on_map_changed(map: DotMapDef, _world: Node) -> void:
	if director != null and map != null:
		director.begin(map.id)


func advance(delta: float) -> void:
	if director != null:
		director.advance(delta)


func rock_the_vote(voter: StringName) -> DotResult:
	return (
		director.rock_the_vote(voter) if director != null
		else DotResult.fail(DotError.CODE_STATE, "No vote is running.")
	)


func nominate(voter: StringName, id: StringName) -> DotResult:
	return (
		director.nominate(voter, id) if director != null
		else DotResult.fail(DotError.CODE_STATE, "No vote is running.")
	)


func cast_one(voter: StringName, choice: StringName) -> DotResult:
	return (
		director.cast_one(voter, choice) if director != null
		else DotResult.fail(DotError.CODE_STATE, "No vote is running.")
	)


func is_voting() -> bool:
	return director != null and director.is_voting()


func forget_voter(voter: StringName) -> void:
	if director != null:
		director.forget_voter(voter)


func timeleft_line() -> String:
	return director.clock.timeleft_line() if director != null else "-"


func next_map() -> String:
	if director == null:
		return "-"

	var pending := director.pending_id()
	return String(pending) if pending != &"" else String(director.next_in_rotation())


func describe_lines() -> PackedStringArray:
	return director.describe_lines() if director != null else PackedStringArray()


func describe() -> Dictionary:
	return {
		"authoritative": authoritative,
		"voters": _player_count(),
		"director": director.describe() if director != null else {},
	}
