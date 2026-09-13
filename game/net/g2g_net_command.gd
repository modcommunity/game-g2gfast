extends DotNetInput

const G2GNetCommand := preload("g2g_net_command.gd")

## One tick of a player's intent, on the wire: a [DotFpsCommand], and the trigger.
##
## [b]The only thing a client may send about itself.[/b] Clients send inputs, never
## state — a client that could send a position could send any position, and dot-net's
## whole security model rests on the distinction. The style, the track and the practice
## keys are requests, not inputs: they change what the simulation IS rather than what
## it does this tick, so they go reliably and rarely through [G2GRequest].
##
## [b]The trigger is here rather than in a request, and that is the whole reason this
## class grew a second field.[/b] A shot happens on a tick and has to be replayed with
## the movement of that tick — prediction rewinds and re-simulates, and a trigger that
## arrived reliably-and-separately would be replayed against a different tick's
## position every time. It is one bit; the aim it is fired along is already here, in
## the movement command's own yaw and pitch.
##
## [b]It is a bit and not a [DotWeaponCommand].[/b] dot-combat's command carries a slot
## request, a reload, an alternate fire and a zoom, and this game has two weapons with
## no magazine between them — so all but one of those fields would be a field nothing
## reads, quantised and sent sixty-four times a second per player. `G2GCombat` builds
## the full command on the server from this bit and the movement's angles, which is the
## same place it would have had to correct a client's aim anyway.

var move: DotFpsCommand = DotFpsCommand.new()

## Whether the attack button is down this tick.
##
## Meaningless on a server with `sv_deathmatch` off, and still sent: one bit per input
## packet is nothing, and a wire whose shape depends on a cvar is a wire two ends can
## disagree about the moment an operator changes it mid-session.
var attack: bool = false


func _write(writer: DotNetWriter) -> void:
	move.write(writer)
	writer.write_bool(attack)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)
	attack = reader.read_bool()


## Not optional. Quantisation bounds each field; it cannot bound the relationship
## between them, and a move vector of (1, 1) is 41% more speed than anybody else.
func _sanitise() -> void:
	move.sanitise()


func _equals(other: DotNetInput) -> bool:
	var them := other as G2GNetCommand
	return them != null and attack == them.attack and move.equals(them.move)
