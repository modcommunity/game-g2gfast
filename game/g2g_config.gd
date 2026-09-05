class_name G2GConfig
extends DotConfig

## Everything a g2gfast server is configured with, in genre units, layered like every
## [DotConfig]: exported defaults, then a JSON file, then [code]G2G_*[/code]
## environment variables, then [code]--g2g-*[/code] arguments.
##
## [b]Every movement field here is one of the genre's cvars by another name[/b], in
## its own units and with its own defaults for a bunny-hop server. An operator who has
## run one of those servers sets [member air_accelerate] to 1000 for bhop and 150 for
## surf without reading anything, which is the point. The conversion to the metres
## the simulation runs in is [G2GMovement]'s, and happens nowhere else.
##
## [b]The tick rate is deliberately not here.[/b] It is dot-server's
## [code]sv_tickrate[/code], and the timer takes it from the engine — see
## [DotTimerConfig]. A second copy of that number is a second number that can
## disagree with the first, and the failure is a leaderboard wrong by their ratio with
## no error anywhere.

@export_group("Bunny-hopping")

## Hold jump to hop. The familiar [code]sv_autobunnyhopping[/code].
##
## [b]The setting this game exists to expose.[/b] Off, a hop has to be timed to the
## tick the player lands on — a keyboard-hardware contest. On, the skill is aiming the
## strafes, which is the actual game. Every modern bhop and surf server runs it on;
## it is on here by default for that reason, and a competition server turns it off.
@export var auto_bhop: bool = true

## Whether hopping may keep and build speed. [code]sv_enablebunnyhopping[/code].
##
## Off applies the landing cap (1.1 × max speed) those games added to [i]stop[/i]
## bunny-hopping. On a bhop server it is on.
@export var enable_bunnyhopping: bool = true

## Seconds before touchdown a jump press is still honoured. 0 is "on the tick".
##
## Only read when [member auto_bhop] is off. The community timers' easy-bhop window.
@export_range(0.0, 0.2, 0.005) var jump_buffer: float = 0.0

@export_group("Movement (genre units)")

## [code]sv_gravity[/code], in units per second squared.
@export_range(1.0, 4000.0, 1.0) var gravity: float = 800.0

## [code]sv_accelerate[/code].
@export_range(0.1, 100.0, 0.1) var accelerate: float = 5.0

## [code]sv_airaccelerate[/code]. 1000 for bhop, 150 for surf, 10 for a stock shooter.
@export_range(0.0, 10000.0, 1.0) var air_accelerate: float = 1000.0

## [code]sv_friction[/code].
@export_range(0.0, 50.0, 0.1) var friction: float = 4.0

## [code]sv_stopspeed[/code], in units per second.
@export_range(0.0, 500.0, 1.0) var stop_speed: float = 75.0

## Run speed, in units per second. The genre's knife speed.
@export_range(10.0, 2000.0, 1.0) var max_speed: float = 250.0

## [code]sv_maxvelocity[/code], in units per second. A backstop, not a gameplay number.
@export_range(100.0, 100000.0, 10.0) var max_velocity: float = 3500.0

## Airborne wish-speed cap, in units per second. Hard-coded at 30 in those games.
@export_range(0.0, 1000.0, 1.0) var air_wish_cap: float = G2GUnits.AIR_WISH_CAP

## Vertical velocity on a jump, in units per second.
@export_range(10.0, 2000.0, 0.1) var jump_velocity: float = G2GUnits.JUMP_VELOCITY

## [code]sv_stepsize[/code], in units.
@export_range(0.0, 64.0, 1.0) var step_size: float = 18.0

## Steepest floor a player can stand on, in degrees. A 0.7 floor normal is 45.57°.
@export_range(1.0, 89.0, 0.1) var max_slope: float = 45.57

## [code]sv_edgefriction[/code]. 1 disables it; those games ship 2.
@export_range(1.0, 10.0, 0.1) var edge_friction: float = 1.0

@export_group("View")

## [code]fov_desired[/code]: horizontal field of view at 4:3, as those games define it.
##
## The one number a player carries between games. See
## [method G2GUnits.horizontal_fov_to_vertical] for why it is not handed to the camera
## directly.
@export_range(30.0, 150.0, 1.0) var fov_desired: float = 90.0

## [code]sensitivity[/code], with the meaning it has everywhere else: degrees per count is this × 0.022.
@export_range(0.01, 50.0, 0.01) var sensitivity: float = 2.5

## Whether players may use the third-person camera at all.
##
## Server-side, because a competition server may want everybody on the same view —
## third person sees over ledges first person cannot.
@export var allow_thirdperson: bool = true

## Which view a player starts in.
@export var default_thirdperson: bool = false

@export_group("Content")

@export var initial_map: StringName = &"bhop_g2g_intro"

## A map catalogue JSON file. Empty uses the maps this build ships.
@export var catalogue_path: String = ""

## Seconds a map runs before the next is chosen. 0 disables it.
@export_range(0.0, 86400.0, 30.0) var map_seconds: float = 1800.0

@export_group("Records")

## Where records go. Empty keeps them in memory only.
@export var records_directory: String = "user://g2gfast/records"

@export var record_replays: bool = true

## Whether the server record's replay runs the map as a ghost everybody can see —
## A replay bot, as every community timer has. Needs [member record_replays].
@export var show_replay_bot: bool = true

## Whether published boards reach the TMC backbone. Off by default: it sends player
## names and times off the server, and that is an operator's decision.
@export var report_to_backbone: bool = false

@export_group("Role")

## Whether this instance times, ranks and decides. A client sets this false.
@export var authoritative: bool = true


func env_prefix() -> String:
	return "G2G_"


func cli_prefix() -> String:
	return "--g2g-"


func validate() -> DotResult:
	if max_speed > max_velocity:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"max_velocity must not be below max_speed.",
			"%.0f vs %.0f u/s" % [max_velocity, max_speed]
		)

	if initial_map == &"":
		return DotResult.fail(
			DotError.CODE_INVALID, "There has to be a map to start on."
		)

	return DotResult.success(null)


func describe_summary() -> String:
	return "autobhop %s, airaccel %.0f, gravity %.0f, fov %.0f, map %s" % [
		"on" if auto_bhop else "off", air_accelerate, gravity, fov_desired,
		String(initial_map),
	]


## The fields that decide how a player moves — what travels to a client, in this
## order, so both ends derive one set of tunables.
const MOVEMENT_FIELDS: Array[String] = [
	"auto_bhop", "enable_bunnyhopping", "jump_buffer", "gravity", "accelerate",
	"air_accelerate", "friction", "stop_speed", "max_speed", "max_velocity",
	"air_wish_cap", "jump_velocity", "step_size", "max_slope", "edge_friction",
]


## Rounds every movement value to what float32 can hold, in place.
##
## That is the precision the wire carries, and a server has to simulate with the
## values its clients received rather than the doubles it read from a file — or the
## two ends derive tunables that differ in the last bit and prediction never
## quite converges, with nothing to point at.
func snap_movement() -> void:
	for field in MOVEMENT_FIELDS:
		var value: Variant = get(field)
		if value is float:
			set(field, PackedFloat32Array([value])[0])
