class_name G2GUnits
extends RefCounted

## The movement genre's units, and the one place they become metres.
##
## [b]This game is configured in genre units on purpose.[/b] A bhop or surf server
## operator knows what [code]sv_airaccelerate 1000[/code] and [code]sv_gravity 800[/code]
## mean, and a leaderboard community knows what 3500 u/s looks like; nobody knows what
## 19.05 m/s² is. So every cvar, every HUD number and every config field here speaks
## those units, and the conversion to the metres the movement simulates in happens
## at exactly one boundary — [G2GMovement] — with this file as the only definition of
## the ratio.
##
## [b]The ratio is 1 unit = 0.75 inch = 1.905 cm[/b], and not the 1-inch figure
## sometimes quoted. It is what the player hull, the eye height and every map in the
## genre were built against: a 72-unit player is 1.37 m tall at this scale and a
## barely-plausible 1.83 m at the other, and a surf ramp imported at the wrong one is
## a ramp the movement cannot hold.

## Metres per genre unit.
const METRES_PER_UNIT := 0.01905

## Genre units per metre. The reciprocal, precomputed because it is used per frame.
const UNITS_PER_METRE := 1.0 / METRES_PER_UNIT

## The genre's player hull, in units. Everything a controller needs is derived.
const PLAYER_HEIGHT := 72.0
const PLAYER_CROUCH_HEIGHT := 54.0
const PLAYER_HALF_WIDTH := 16.0
const PLAYER_EYE_HEIGHT := 64.0
const PLAYER_CROUCH_EYE_HEIGHT := 46.0

## The genre's hard-coded cap on airborne wish speed, in units per second.
##
## The number the whole of air-strafing rests on — see [method DotFpsMotor.accelerate].
## Not adjustable in the games this comes from; exposed as a cvar here because a
## movement server wants it.
const AIR_WISH_CAP := 30.0

## The genre's vertical velocity after a jump, in units per second.
##
## [code]sqrt(2 * 800 * 57)[/code] — 57 units of jump height under default gravity —
## rounded to what the community quotes.
const JUMP_VELOCITY := 301.993377


static func to_metres(units: float) -> float:
	return units * METRES_PER_UNIT


static func to_units(metres: float) -> float:
	return metres * UNITS_PER_METRE


static func vector_to_metres(units: Vector3) -> Vector3:
	return units * METRES_PER_UNIT


static func vector_to_units(metres: Vector3) -> Vector3:
	return metres * UNITS_PER_METRE


## A speed in units per second, as a HUD shows it: whole units, no decimals.
static func format_speed(metres_per_second: float) -> String:
	return "%d" % int(round(to_units(metres_per_second)))


## The genre's horizontal field of view into the vertical one Godot's camera wants.
##
## [b]A [code]fov_desired[/code] of 90 means 90° horizontal at 4:3, and that is the
## whole subtlety.[/b] These games store FoV as horizontal on a 4:3 frame and widen it
## for a wider screen, so the same setting shows more on a 16:9 monitor — which is what
## every player's muscle memory expects. Godot's [Camera3D] takes a vertical angle and
## keeps it fixed as the aspect changes. Converting through the 4:3 frame gives a
## vertical angle that reproduces the original exactly: 90 becomes 73.74°, and on 16:9
## the camera then shows 106.26° horizontally, which is what those games show.
##
## Setting Godot's fov to 90 directly — the obvious thing — gives a vertical 90, a
## horizontal 121° on 16:9, and a player who feels seasick and cannot say why.
static func horizontal_fov_to_vertical(fov_desired: float) -> float:
	var horizontal := deg_to_rad(clampf(fov_desired, 30.0, 150.0))
	return rad_to_deg(2.0 * atan(tan(horizontal * 0.5) * 3.0 / 4.0))


## The familiar [code]sensitivity[/code] cvar into degrees per mouse count.
##
## Those games turn the view by [code]sensitivity × m_yaw[/code] degrees per count, with
## [code]m_yaw 0.022[/code] — so a player's sensitivity of 2.5 is 0.055°/count, and the
## number they have carried between games for fifteen years works here unchanged.
static func sensitivity_to_degrees(sensitivity: float, m_yaw: float = 0.022) -> float:
	return maxf(sensitivity, 0.0) * m_yaw
