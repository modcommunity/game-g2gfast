extends G2GMap

## `bhop_g2g_intro` — sixteen blocks with widening gaps, three stages, and a bonus.
##
## Built in genre units so it reads like a brush list. The gaps grow from 96
## to 288 units: at 250 u/s a standing jump clears about 190, so from the tenth block
## on the only way across is to have kept the speed from the earlier ones — which
## means landing and jumping on the same tick, every time, which is the whole skill.
## With [code]sv_autobunnyhopping 1[/code] that is holding the key and aiming; with it
## off, it is the tick.
##
## The bonus is a short side route off the start pad: three wide platforms and a
## finish, for a player who wants a warm-up.

const BLOCKS := 16
const BLOCK_LENGTH := 160.0
const BLOCK_WIDTH := 192.0
const BLOCK_THICKNESS := 32.0
const FIRST_GAP := 96.0
const LAST_GAP := 288.0

const START_Z := 0.0
const FLOOR_Y := 0.0


func _build() -> void:
	tier = 2
	G2GGeometry.sun(self)
	fallback_spawn_units = Vector3(0.0, FLOOR_Y + 8.0, START_Z + 320.0)

	# The start pad, long enough to build speed on.
	G2GGeometry.box(
		self, Vector3(0.0, FLOOR_Y - BLOCK_THICKNESS * 0.5, START_Z + 256.0),
		Vector3(BLOCK_WIDTH, BLOCK_THICKNESS, 512.0), G2GGeometry.COLOUR_START
	)

	var z := START_Z

	for i in range(BLOCKS):
		G2GGeometry.box(
			self,
			Vector3(0.0, FLOOR_Y - BLOCK_THICKNESS * 0.5, z - BLOCK_LENGTH * 0.5),
			Vector3(BLOCK_WIDTH, BLOCK_THICKNESS, BLOCK_LENGTH),
			G2GGeometry.COLOUR_PLATFORM
		)
		z -= BLOCK_LENGTH + gap_at(i)

	# The finish pad.
	G2GGeometry.box(
		self, Vector3(0.0, FLOOR_Y - BLOCK_THICKNESS * 0.5, z - 192.0),
		Vector3(BLOCK_WIDTH, BLOCK_THICKNESS, 384.0), G2GGeometry.COLOUR_END
	)

	# The bonus: off to the right of the start pad, three big platforms and a pad.
	for i in range(3):
		G2GGeometry.box(
			self,
			Vector3(640.0 + float(i) * 320.0, FLOOR_Y - BLOCK_THICKNESS * 0.5, START_Z + 256.0),
			Vector3(192.0, BLOCK_THICKNESS, 192.0), G2GGeometry.COLOUR_BONUS
		)

	G2GGeometry.box(
		self, Vector3(1600.0, FLOOR_Y - BLOCK_THICKNESS * 0.5, START_Z + 256.0),
		Vector3(256.0, BLOCK_THICKNESS, 256.0), G2GGeometry.COLOUR_END
	)


static func gap_at(index: int) -> float:
	return lerpf(FIRST_GAP, LAST_GAP, float(index) / float(maxi(BLOCKS - 1, 1)))


static func end_z() -> float:
	var z := START_Z
	for i in range(BLOCKS):
		z -= BLOCK_LENGTH + gap_at(i)
	return z


## Z of the front edge of block [param index], for placing stage lines.
static func block_z(index: int) -> float:
	var z := START_Z
	for i in range(index):
		z -= BLOCK_LENGTH + gap_at(i)
	return z


func timer_zones() -> DotTimerZoneSet:
	return build_zones()


static func build_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = &"bhop_g2g_intro"
	zones.meta["tier"] = 2
	zones.meta["author"] = "g2gfast"

	var main := DotTimerTrack.MAIN
	var finish_z := end_z()

	zones.add(zone_box(DotTimerZone.Kind.START, main,
		Vector3(-96.0, FLOOR_Y, START_Z), Vector3(96.0, FLOOR_Y + 128.0, START_Z + 512.0)))
	zones.add(zone_box(DotTimerZone.Kind.END, main,
		Vector3(-96.0, FLOOR_Y, finish_z - 384.0), Vector3(96.0, FLOOR_Y + 128.0, finish_z - 64.0)))

	# Stages on blocks 5, 10 and 14, spanning the block so a fast player cannot pass
	# through the line between two ticks.
	var stage_blocks := [5, 10, 14]
	for i in range(stage_blocks.size()):
		var bz := block_z(stage_blocks[i])
		var stage := zone_box(DotTimerZone.Kind.STAGE, main,
			Vector3(-96.0, FLOOR_Y, bz - BLOCK_LENGTH), Vector3(96.0, FLOOR_Y + 128.0, bz))
		stage.number = float(i + 1)
		zones.add(stage)

	zones.add(zone_box(DotTimerZone.Kind.RESPAWN, main,
		Vector3(-4096.0, FLOOR_Y - 1024.0, finish_z - 4096.0),
		Vector3(4096.0, FLOOR_Y - 192.0, START_Z + 4096.0)))

	zones.add(zone_spawn(main, Vector3(0.0, FLOOR_Y + 8.0, START_Z + 400.0), 0.0))

	# The bonus.
	var bonus := DotTimerTrack.of_bonus(1)
	zones.add(zone_box(DotTimerZone.Kind.START, bonus,
		Vector3(544.0, FLOOR_Y, START_Z + 160.0), Vector3(736.0, FLOOR_Y + 128.0, START_Z + 352.0)))
	zones.add(zone_box(DotTimerZone.Kind.END, bonus,
		Vector3(1472.0, FLOOR_Y, START_Z + 128.0), Vector3(1728.0, FLOOR_Y + 128.0, START_Z + 384.0)))
	zones.add(zone_spawn(bonus, Vector3(640.0, FLOOR_Y + 8.0, START_Z + 256.0), -90.0))

	return zones
