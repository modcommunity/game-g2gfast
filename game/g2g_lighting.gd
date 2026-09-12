class_name G2GLighting
extends RefCounted

## This game's lighting, which is [DotLightRig] and one decision of its own.
##
## [b]It used to be the implementation and is now the caller.[/b] Reading a map's own sun,
## ambient, fog and sky out of a manifest and turning them into an [Environment] is not a
## thing about a bhop timer — it is a thing about any game that loads a world somebody else
## authored — so it is dot-lighting now, with its own suite, and what stays here is the
## part that is genuinely this game's: which profile a machine gets.
##
## See Decision 13 in this project's CLAUDE.md for what the lighting block is and where it
## comes from.


## Applies the lighting a manifest carries and returns the sun.
static func apply(parent: Node3D, lighting: Dictionary) -> DirectionalLight3D:
	return DotLightRig.apply(
		parent, DotLightDocument.from_dictionary(lighting), profile()
	)


## What this machine draws.
##
## [b]Shadows off in a browser and glow kept, which is dot-lighting's `web()` and is doubly
## right here.[/b] A surf map is a large open volume — a shadow pass costs what is in frame
## and on a canyon that is the canyon — while the glow is what makes a neon strip read as a
## light, and a neon strip is how one of these maps signposts the route. Dropping the thing
## a player navigates by to save a cost they cannot see would be the wrong trade even if
## the two cost the same.
static func profile() -> DotLightProfile:
	return DotLightProfile.web() if _is_web() else DotLightProfile.high()


static func _is_web() -> bool:
	# The family rule is to ask about the capability rather than the platform. There is no
	# capability query for "this GPU is slow", so this is one of the few places where the
	# platform IS the question: a browser's renderer is the constraint, whatever it runs on.
	return OS.has_feature("web")


## What a map's lighting amounts to, for a console command or a bug report.
static func describe_lines(lighting: Dictionary) -> PackedStringArray:
	return DotLightDocument.from_dictionary(lighting).describe_lines()
