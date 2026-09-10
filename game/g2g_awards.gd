class_name G2GAwards
extends RefCounted

## What a player earns on a timer server, as a document rather than as code.
##
## Every rule reads an id from [G2GStats] and nothing else. dot-achievements never
## hears about a run, a ramp or a strafe — it hears that a number moved.
##
## [b]One stat may be read with only one merge rule across the catalogue[/b], and
## dot-achievements refuses one that breaks it at validate rather than at the first
## reading: one number cannot be both a running total and a personal best. So
## [constant G2GStats.BEST_TIME] is always LOWEST, [constant G2GStats.TOP_SPEED] is
## always HIGHEST, and everything else is SUM. The helpers are the only reason that
## cannot be got wrong one entry at a time.
##
## [b]The one worth reading twice is `sub_thirty`.[/b] "Finish a map in under thirty
## seconds" is a LOWEST stat with an AT_MOST rule — and dot-achievements' own note says
## what that means for a player who has never been recorded: a missing stat reads as
## zero, and "at most 30" is satisfied by zero. It is guarded by a second rule
## requiring a finished run, because the alternative is every new player unlocking it
## for having done nothing.

const CHANNEL := "g2g.awards"

const CAT_TIMER := &"timer"
const CAT_MOVEMENT := &"movement"
const CAT_SERVER := &"server"
const CAT_COMBAT := &"combat"


static func catalogue() -> DotAchievementCatalogue:
	var out: Array[DotAchievement] = []

	# --- Finishing --------------------------------------------------------
	out.append(_sum(
		&"g2g.first_finish", "Made It", G2GStats.RUNS_FINISHED, 1,
		"Finish a course.", CAT_TIMER, 5, &"g2g.finisher", 1
	))
	out.append(_sum(
		&"g2g.hundred_finishes", "Regular", G2GStats.RUNS_FINISHED, 100,
		"A hundred finished runs.", CAT_TIMER, 25, &"g2g.finisher", 2
	))
	out.append(_sum(
		&"g2g.thousand_finishes", "Fixture", G2GStats.RUNS_FINISHED, 1000,
		"A thousand finished runs.", CAT_TIMER, 100, &"g2g.finisher", 3
	))

	# --- Records ----------------------------------------------------------
	out.append(_sum(
		&"g2g.first_pb", "Personal Best", G2GStats.RECORDS_SET, 1,
		"Beat your own time.", CAT_TIMER, 10
	))
	out.append(_sum(
		&"g2g.first_wr", "Top of the Board", G2GStats.WORLD_RECORDS, 1,
		"Take a server record.", CAT_TIMER, 40, &"g2g.record_holder", 1
	))
	out.append(_sum(
		&"g2g.ten_wr", "Record Holder", G2GStats.WORLD_RECORDS, 10,
		"Hold ten server records.", CAT_TIMER, 90, &"g2g.record_holder", 2
	))

	# --- A time, which is the awkward one ---------------------------------
	#
	# See the class note: a LOWEST stat with an AT_MOST rule is satisfied by a player
	# who has never been recorded at all, because a missing stat reads as zero. The
	# second rule is what makes it mean what it says.
	var quick: Array[DotAchievementRule] = [
		DotAchievementRule.make(
			G2GStats.BEST_TIME, 30.0,
			DotAchievementRule.Op.AT_MOST, DotAchievementRule.Merge.LOWEST
		),
		DotAchievementRule.make(G2GStats.RUNS_FINISHED, 1.0),
	]
	var sub_thirty := DotAchievement.make(&"g2g.sub_thirty", "Under Thirty", quick)
	sub_thirty.description = "Finish a course in under thirty seconds."
	sub_thirty.category = CAT_TIMER
	sub_thirty.points = 30
	out.append(sub_thirty)

	# --- Movement ---------------------------------------------------------
	out.append(_sum(
		&"g2g.ten_thousand_jumps", "Springs", G2GStats.JUMPS, 10000,
		"Ten thousand jumps.", CAT_MOVEMENT, 25
	))

	# A perfect jump is one that landed and left on the same tick. Five thousand of
	# them is a player who can actually bhop, which is a different claim from having
	# jumped a lot — hence a separate entry rather than a ratio.
	out.append(_sum(
		&"g2g.perfect_thousand", "Frame Perfect", G2GStats.PERFECT_JUMPS, 5000,
		"Five thousand perfect jumps.", CAT_MOVEMENT, 60
	))

	out.append(_best(
		&"g2g.fast_mover", "Terminal", G2GStats.TOP_SPEED, 2000,
		"Reach 2000 u/s.", CAT_MOVEMENT, 40, &"g2g.speed", 1
	))
	out.append(_best(
		&"g2g.very_fast_mover", "Escape Velocity", G2GStats.TOP_SPEED, 3500,
		"Reach 3500 u/s.", CAT_MOVEMENT, 90, &"g2g.speed", 2
	))

	out.append(_sum(
		&"g2g.marathon", "Marathon", G2GStats.DISTANCE, 42195,
		"Travel a marathon.", CAT_MOVEMENT, 50
	))

	# --- The server -------------------------------------------------------
	out.append(_sum(
		&"g2g.tourist", "Tourist", G2GStats.MAPS_PLAYED, 25,
		"Play twenty-five maps.", CAT_SERVER, 20
	))
	out.append(_sum(
		&"g2g.resident", "Resident", G2GStats.PLAYTIME_SEC, 86400,
		"Twenty-four hours on the server.", CAT_SERVER, 60
	))

	# --- The other halves -------------------------------------------------
	out.append(_sum(
		&"g2g.duellist", "Duellist", G2GStats.KILLS, 100,
		"A hundred kills in deathmatch.", CAT_COMBAT, 25
	))
	out.append(_sum(
		&"g2g.hunted", "Hunted", G2GStats.HUNTERS_KILLED, 50,
		"Put down fifty hunters.", CAT_COMBAT, 30
	))

	return DotAchievementCatalogue.of(out)


static func _sum(
	id: StringName, display: String, stat: StringName, threshold: float,
	description: String, category: StringName, points: int,
	series: StringName = &"", tier: int = 0
) -> DotAchievement:
	return _entry(
		id, display, stat, threshold, DotAchievementRule.Merge.SUM,
		description, category, points, series, tier
	)


static func _best(
	id: StringName, display: String, stat: StringName, threshold: float,
	description: String, category: StringName, points: int,
	series: StringName = &"", tier: int = 0
) -> DotAchievement:
	return _entry(
		id, display, stat, threshold, DotAchievementRule.Merge.HIGHEST,
		description, category, points, series, tier
	)


static func _entry(
	id: StringName, display: String, stat: StringName, threshold: float,
	merge: DotAchievementRule.Merge, description: String, category: StringName,
	points: int, series: StringName, tier: int
) -> DotAchievement:
	var rules: Array[DotAchievementRule] = [
		DotAchievementRule.make(stat, threshold, DotAchievementRule.Op.AT_LEAST, merge)
	]
	var out := DotAchievement.make(id, display, rules)
	out.description = description
	out.category = category
	out.points = points
	out.series = series
	out.tier = tier
	return out
