class_name G2GNetCommand
extends DotNetInput

## One tick of a player's intent, on the wire: a [DotFpsCommand] and nothing else.
##
## [b]The only thing a client may send about itself.[/b] Clients send inputs, never
## state — a client that could send a position could send any position, and dot-net's
## whole security model rests on the distinction. The style, the track and the practice
## keys are requests, not inputs: they change what the simulation IS rather than what
## it does this tick, so they go reliably and rarely through [G2GRequest].

var move: DotFpsCommand = DotFpsCommand.new()


func _write(writer: DotNetWriter) -> void:
	move.write(writer)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)


## Not optional. Quantisation bounds each field; it cannot bound the relationship
## between them, and a move vector of (1, 1) is 41% more speed than anybody else.
func _sanitise() -> void:
	move.sanitise()


func _equals(other: DotNetInput) -> bool:
	var them := other as G2GNetCommand
	return them != null and move.equals(them.move)
