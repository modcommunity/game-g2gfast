extends "../game/g2g_map.gd"

const G2GGeometry := preload("../game/g2g_geometry.gd")

## `surf_g2g_intro` — two ramps meeting in a valley, descending, with a bonus.
##
## Surf ramps are built at angles a player cannot stand on — the standable
## limit is a normal of 0.7, about 45.6° — and this one is 60°. The player drops off
## the start platform onto a face too steep to stand on, slides under gravity, and
## strafes to keep and gain speed. The seam between the two ramps is the geometry
## dot-player-controller's crease resolution exists for.
##
## Everything in genre units. The valley falls 3072 units over 8192.

const START_Z := 0.0
const END_Z := -8192.0
const START_Y := 2048.0
const END_Y := -1024.0
const VALLEY_HALF_WIDTH := 96.0
const RAMP_WIDTH := 1024.0
const RAMP_ANGLE := 60.0
const RAMP_THICKNESS := 32.0


func _build() -> void:
	tier = 3
	G2GGeometry.sun(self)
	fallback_spawn_units = Vector3(0.0, START_Y + 8.0, START_Z + 256.0)

	# Start platform with a back wall.
	G2GGeometry.box(self, Vector3(0.0, START_Y - 16.0, START_Z + 256.0),
		Vector3(768.0, 32.0, 512.0), G2GGeometry.COLOUR_START)
	G2GGeometry.box(self, Vector3(0.0, START_Y + 64.0, START_Z + 520.0),
		Vector3(768.0, 160.0, 32.0), G2GGeometry.COLOUR_PLATFORM)

	var length := absf(END_Z - START_Z)
	var centre_z := (START_Z + END_Z) * 0.5
	var lift := sin(deg_to_rad(RAMP_ANGLE)) * RAMP_WIDTH * 0.5
	var out := cos(deg_to_rad(RAMP_ANGLE)) * RAMP_WIDTH * 0.5

	for side in [-1.0, 1.0]:
		G2GGeometry.ramp(
			self,
			Vector3(side * (VALLEY_HALF_WIDTH + out), (START_Y + END_Y) * 0.5 + lift, centre_z),
			Vector3(RAMP_WIDTH, RAMP_THICKNESS, length),
			-side * RAMP_ANGLE, Vector3.FORWARD
		)

	# The descending valley floor, in steps.
	var steps := 16
	for i in range(steps):
		var t := float(i) / float(steps - 1)
		G2GGeometry.box(
			self,
			Vector3(0.0, lerpf(START_Y - 256.0, END_Y, t) - 16.0, lerpf(START_Z - 256.0, END_Z + 256.0, t)),
			Vector3(VALLEY_HALF_WIDTH * 2.0, 32.0, length / float(steps) + 64.0),
			G2GGeometry.COLOUR_FLOOR
		)

	# Finish pad.
	G2GGeometry.box(self, Vector3(0.0, END_Y - 16.0, END_Z - 320.0),
		Vector3(768.0, 32.0, 640.0), G2GGeometry.COLOUR_END)

	# Bonus: a single short ramp beside the start.
	G2GGeometry.box(self, Vector3(1536.0, START_Y - 16.0, START_Z + 256.0),
		Vector3(384.0, 32.0, 384.0), G2GGeometry.COLOUR_BONUS)
	G2GGeometry.ramp(self, Vector3(1536.0 + 256.0, START_Y - 200.0, START_Z - 800.0),
		Vector3(768.0, RAMP_THICKNESS, 2048.0), -RAMP_ANGLE, Vector3.FORWARD, G2GGeometry.COLOUR_BONUS)
	G2GGeometry.box(self, Vector3(1536.0, START_Y - 1200.0 - 16.0, START_Z - 2200.0),
		Vector3(512.0, 32.0, 512.0), G2GGeometry.COLOUR_END)

	# Bonus 2: the transfer, on the other side of the start.
	#
	# [b]A different skill from bonus 1, not a longer version of it.[/b] That one is a
	# single bank: get on it, hold it, ride it down. This is two banked the opposite
	# way with a gap between them, so the run ends at the moment the first ramp stops
	# and the player has to be airborne, pointed, and moving in the right direction to
	# catch the second. Which way a surface throws you is the whole of surf, and a map
	# with one ramp never asks the question twice.
	#
	# The direction each one throws is worth writing down, because it is the sign that
	# is wrong first: `G2GGeometry.ramp` rotates about +Z, so a POSITIVE angle lifts
	# the -X edge and the player slides toward +X. Bonus 1 uses the negative and runs
	# the other way, which is why these numbers are not its mirror.
	G2GGeometry.box(self, Vector3(-1536.0, START_Y - 16.0, START_Z + 256.0),
		Vector3(384.0, 32.0, 384.0), G2GGeometry.COLOUR_BONUS)

	# [b]A banked ramp is narrower in X than it is wide.[/b] At 60 degrees a 768-unit
	# ramp occupies 768 * cos(60) = 384 units of X, so its lip is 192 either side of
	# its centre and not 384 -- and its surface climbs 192 * tan(60) = 333 units over
	# that. Every number below is placed off those two, because the first draft put
	# the pad over a strip of X the ramp did not reach and the bot walked into the pit.
	#
	# Ramp one is centred UNDER the pad rather than beside it. The drop is 250 units
	# onto the middle of the bank, which is a landing rather than an edge catch.
	G2GGeometry.ramp(self, Vector3(-1536.0, START_Y - 250.0, START_Z - 600.0),
		Vector3(768.0, RAMP_THICKNESS, 1600.0), RAMP_ANGLE, Vector3.FORWARD,
		G2GGeometry.COLOUR_BONUS)

	# And back the other way. Its high side sits at x -1300, just past where the first
	# one's lip throws the player out at -1344, and 117 units below it -- so the
	# transfer is a short fall onto a surface banked the opposite way rather than a
	# gap that has to be jumped. The two meet in Z rather than leaving air between
	# them: the skill being asked for is reading which way a surface throws you, and
	# a hundred units of nothing in the middle of it turns that into a coin flip.
	#
	# [b]It runs the whole length of the first one, not the back half of it.[/b] A
	# banked ramp throws you off its lip wherever you happen to reach it, and the first
	# draft put the second ramp only under the last third of the first -- so a player
	# who came off early fell through the gap between them and out of the level. Which
	# is a route that works if you already know where the catch is, and is nothing if
	# you do not.
	G2GGeometry.ramp(self, Vector3(-1492.0, START_Y - 1033.0, START_Z - 1000.0),
		Vector3(768.0, RAMP_THICKNESS, 2800.0), -RAMP_ANGLE, Vector3.FORWARD,
		G2GGeometry.COLOUR_BONUS)

	# A floor under the whole thing, falling toward the finish in steps, the way the
	# main track's valley does. On a tier-3 map's bonus the punishment for losing the
	# bank is losing the time, not losing the run: the floor is slow, it is reachable,
	# and it ends at the same pad the ramps do.
	var bonus_steps := 8
	for i in range(bonus_steps):
		var t := float(i) / float(bonus_steps - 1)
		G2GGeometry.box(
			self,
			Vector3(-1500.0, lerpf(START_Y - 700.0, START_Y - 1500.0, t) - 16.0,
				lerpf(START_Z, START_Z - 3000.0, t)),
			Vector3(640.0, 32.0, 3000.0 / float(bonus_steps) + 64.0),
			G2GGeometry.COLOUR_FLOOR
		)

	G2GGeometry.box(self, Vector3(-1500.0, START_Y - 1560.0 - 16.0, START_Z - 3300.0),
		Vector3(768.0, 32.0, 640.0), G2GGeometry.COLOUR_END)


func timer_zones() -> DotTimerZoneSet:
	return build_zones()


static func build_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = &"surf_g2g_intro"
	zones.meta["tier"] = 3
	zones.meta["author"] = "g2gfast"

	var main := DotTimerTrack.MAIN

	zones.add(zone_box(DotTimerZone.Kind.START, main,
		Vector3(-384.0, START_Y, START_Z), Vector3(384.0, START_Y + 256.0, START_Z + 512.0)))
	zones.add(zone_box(DotTimerZone.Kind.END, main,
		Vector3(-384.0, END_Y, END_Z - 640.0), Vector3(384.0, END_Y + 512.0, END_Z - 128.0)))

	# Each stage line carries where `!s<n>` puts a player: above the ramp mouth at
	# that height, facing down the run. A surf stage restart is worth more than a bhop
	# one — the alternative is riding the whole descent again to reach the section
	# being learned — and it is the reason `restart_stage` exists at all.
	for i in range(1, 3):
		var t := float(i) / 3.0
		var z := lerpf(START_Z, END_Z, t)
		var y := lerpf(START_Y, END_Y, t)
		zones.add(zone_stage(
			main, i,
			Vector3(-1200.0, y - 900.0, z - 96.0),
			Vector3(1200.0, y + 900.0, z + 96.0),
			Vector3(0.0, y + 192.0, z + 64.0),
			180.0
		))

	zones.add(zone_box(DotTimerZone.Kind.RESPAWN, main,
		Vector3(-16384.0, END_Y - 4096.0, END_Z - 16384.0),
		Vector3(16384.0, END_Y - 1536.0, START_Z + 16384.0)))
	zones.add(zone_spawn(main, Vector3(0.0, START_Y + 8.0, START_Z + 320.0), 0.0))

	var bonus := DotTimerTrack.of_bonus(1)
	zones.add(zone_box(DotTimerZone.Kind.START, bonus,
		Vector3(1344.0, START_Y, START_Z + 64.0), Vector3(1728.0, START_Y + 256.0, START_Z + 448.0)))
	zones.add(zone_box(DotTimerZone.Kind.END, bonus,
		Vector3(1280.0, START_Y - 1300.0, START_Z - 2456.0), Vector3(1792.0, START_Y - 900.0, START_Z - 1944.0)))
	zones.add(zone_spawn(bonus, Vector3(1536.0, START_Y + 8.0, START_Z + 300.0), 0.0))

	var transfer := DotTimerTrack.of_bonus(2)
	zones.add(zone_box(DotTimerZone.Kind.START, transfer,
		Vector3(-1728.0, START_Y, START_Z + 64.0), Vector3(-1344.0, START_Y + 256.0, START_Z + 448.0)))
	zones.add(zone_box(DotTimerZone.Kind.END, transfer,
		Vector3(-1884.0, START_Y - 1700.0, START_Z - 3620.0),
		Vector3(-1116.0, START_Y - 1180.0, START_Z - 2980.0)))
	zones.add(zone_spawn(transfer, Vector3(-1536.0, START_Y + 8.0, START_Z + 300.0), 0.0))

	# [b]A respawn zone per bonus, because a zone belongs to a track.[/b] The main
	# track has had one since the map was written and both bonuses had none, so a
	# player who missed a bonus ramp did not get put back -- they fell, and kept
	# falling, for as long as they were prepared to watch. It is the main track's own
	# bug from before `DotTimer.effect_requested` was connected, still live on two
	# tracks, and it stayed invisible because nothing had ever driven a bonus.
	for track in [bonus, transfer]:
		zones.add(zone_box(DotTimerZone.Kind.RESPAWN, track,
			Vector3(-16384.0, END_Y - 4096.0, END_Z - 16384.0),
			Vector3(16384.0, END_Y - 1536.0, START_Z + 16384.0)))

	return zones
