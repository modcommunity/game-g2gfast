extends G2GMap

## `surf_g2g_intro` — two ramps meeting in a valley, descending, with a bonus.
##
## Surf ramps are built at angles a player cannot stand on — the standable
## limit is a normal of 0.7, about 45.6° — and this one is 60°. The player drops off
## the start platform onto a face too steep to stand on, slides under gravity, and
## strafes to keep and gain speed. The seam between the two ramps is the geometry
## dot-fps-controller's crease resolution exists for.
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

	for i in range(1, 3):
		var t := float(i) / 3.0
		var z := lerpf(START_Z, END_Z, t)
		var y := lerpf(START_Y, END_Y, t)
		var stage := zone_box(DotTimerZone.Kind.STAGE, main,
			Vector3(-1200.0, y - 900.0, z - 96.0), Vector3(1200.0, y + 900.0, z + 96.0))
		stage.number = float(i)
		zones.add(stage)

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

	return zones
