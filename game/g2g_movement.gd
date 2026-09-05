class_name G2GMovement
extends RefCounted

## Turns a [G2GConfig] — genre units, the genre's cvars — into the [DotFpsTunables] the
## motor simulates with.
##
## [b]The only place units cross.[/b] Everything above this speaks units per second;
## everything below speaks metres. A conversion anywhere else is a second copy of the
## ratio, and two copies of a ratio drift.
##
## [b]Rebuilt whenever a cvar changes, and every player is handed the result.[/b] The
## tunables are an input to the simulation, so a server running players on two
## different sets is a server whose records are not comparable with each other — which
## is why [method G2GGame.apply_movement] abandons every run in progress when it
## swaps them, exactly as a tick-rate change does.


## The tunables for a configuration.
##
## A fresh resource every call, never a shared one edited in place: the controller
## keeps a reference to what it was built with and derives styles from it, so editing
## the shared object under thirty players would change all of them at once and leave
## the styles compounding on a base that had moved.
static func tunables_for(config: G2GConfig) -> DotFpsTunables:
	var t := DotFpsTunables.new()

	# --- Speeds -----------------------------------------------------------
	t.max_speed = G2GUnits.to_metres(config.max_speed)
	t.max_velocity = G2GUnits.to_metres(config.max_velocity)

	# These games have no sprint and no walk-speed modifier that matters to a
	# timer; a style may still scale the base. Crouch-walking at 0.34 is the genre's
	# duck speed fraction.
	t.can_sprint = false
	t.can_walk = false
	t.crouch_speed_scale = 0.34
	t.backward_speed_scale = 1.0

	# --- Ground -----------------------------------------------------------
	t.accelerate = config.accelerate
	t.friction = config.friction
	t.stop_speed = G2GUnits.to_metres(config.stop_speed)
	t.edge_friction = config.edge_friction

	# --- Air ----------------------------------------------------------------
	t.air_accelerate = config.air_accelerate
	t.max_air_wish_speed = G2GUnits.to_metres(config.air_wish_cap)
	t.gravity = G2GUnits.to_metres(config.gravity)
	t.air_friction = 0.0

	# --- Jumping ------------------------------------------------------------
	#
	# The tunables take a jump HEIGHT and derive the launch speed from gravity, so
	# the height is what reproduces the genre's launch speed under this gravity:
	# h = v² / 2g. Under 800 u/s² that is 57 units, the number every bhop player
	# knows.
	var v := G2GUnits.to_metres(config.jump_velocity)
	t.jump_height = (v * v) / (2.0 * maxf(t.gravity, 0.001))

	t.auto_hop = config.auto_bhop
	# Auto-hop has no use for a buffer — the key is held — and a buffer on a
	# non-auto server IS easy-bhop, so the two are one field here and two cvars
	# there.
	t.jump_buffer_time = 0.0 if config.auto_bhop else config.jump_buffer
	# Coyote time is free speed on a timed map, and a run set with it is not
	# comparable with one set without.
	t.coyote_time = 0.0
	t.jump_cooldown = 0.0
	t.jump_adds_to_velocity = false

	# sv_enablebunnyhopping off is the landing cap those games added, which the
	# controller ships as a cap on jump speed at 1.1 × max_speed.
	t.bhop_speed_cap_scale = 0.0 if config.enable_bunnyhopping else 1.1

	# --- The hull -----------------------------------------------------------
	t.stand_height = G2GUnits.to_metres(G2GUnits.PLAYER_HEIGHT)
	t.crouch_height = G2GUnits.to_metres(G2GUnits.PLAYER_CROUCH_HEIGHT)
	t.radius = G2GUnits.to_metres(G2GUnits.PLAYER_HALF_WIDTH)
	t.instant_air_crouch = true
	t.crouch_transition_time = 0.1

	# --- Collision ----------------------------------------------------------
	t.max_slope_angle = config.max_slope
	t.step_height = G2GUnits.to_metres(config.step_size)
	t.ground_snap = true
	t.crease_slide = true

	# --- Look ---------------------------------------------------------------
	t.mouse_sensitivity = G2GUnits.sensitivity_to_degrees(config.sensitivity)

	return t


## The stand height the hull implies, for a rig that has to be the same size.
static func player_height() -> float:
	return G2GUnits.to_metres(G2GUnits.PLAYER_HEIGHT)


## Where those games put the eye, as a fraction of the hull. The view uses the motor's
## own eye position; this is for a rig deciding where a head goes.
static func eye_fraction() -> float:
	return G2GUnits.PLAYER_EYE_HEIGHT / G2GUnits.PLAYER_HEIGHT
