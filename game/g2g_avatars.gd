class_name G2GAvatars
extends RefCounted

## The stock characters, the schema they fit, and how a player's own avatar replaces
## them.
##
## [b]One schema, two sources of parts.[/b] dot-user-avatar describes an avatar as a
## document — slots and part ids — that a server validates without loading a mesh,
## and a rig is a set of named attachment nodes the parts are instantiated under. So
## the stock characters here and a player's own avatar from the platform are the same
## thing at different addresses: the stock parts ship in this build under
## [code]res://avatars/[/code], a platform part names dot-cloud content, and
## [DotAvatarBuilder] does not care which it got.
##
## A player with no avatar of their own gets [method stock_avatar], which is a real
## document over the same schema rather than a special case — so a server that has
## never talked to the backbone still draws everybody, and the day it does, nothing
## about how a player is drawn changes.

## The schema id every g2gfast avatar conforms to.
const SCHEMA_ID := &"g2g_stock"

## Slots, in draw order. The rig has one attachment node per slot, named for it.
const SLOT_BODY := &"body"
const SLOT_HEAD := &"head"
const SLOT_HAT := &"hat"

## Stock part ids. Every one of them is a scene under res://avatars/.
const BODIES: Array[StringName] = [&"body_stock", &"body_slim"]
const HEADS: Array[StringName] = [&"head_stock", &"head_box"]
const HATS: Array[StringName] = [&"hat_cap", &"hat_cone"]

## Tints a stock character gets, by player, so two stock players are not identical.
##
## Chosen by hashing the player id rather than at random, so a player is the same
## colour on every machine and every visit — a colour that changed per session would
## read as "that is a different person".
const PALETTE: Array[Color] = [
	Color(0.85, 0.30, 0.25), Color(0.25, 0.60, 0.90), Color(0.35, 0.75, 0.40),
	Color(0.90, 0.70, 0.20), Color(0.70, 0.40, 0.85), Color(0.90, 0.50, 0.65),
	Color(0.30, 0.80, 0.80), Color(0.80, 0.55, 0.30),
]


## Builds the schema. Once per game; it is content, not state.
static func schema() -> DotAvatarSchema:
	var s := DotAvatarSchema.new()
	s.id = SCHEMA_ID
	s.version = 1

	var body := DotAvatarSlot.new()
	body.id = SLOT_BODY
	body.display_name = "Body"
	body.required = true
	body.default_part = BODIES[0]
	body.layer = 10
	s.slots.append(body)

	var head := DotAvatarSlot.new()
	head.id = SLOT_HEAD
	head.display_name = "Head"
	head.required = true
	head.default_part = HEADS[0]
	head.layer = 20
	s.slots.append(head)

	var hat := DotAvatarSlot.new()
	hat.id = SLOT_HAT
	hat.display_name = "Hat"
	hat.required = false
	hat.layer = 30
	s.slots.append(hat)

	for id in BODIES:
		s.parts.append(_part(id, SLOT_BODY, 1))
	for id in HEADS:
		s.parts.append(_part(id, SLOT_HEAD, 1))
	for id in HATS:
		s.parts.append(_part(id, SLOT_HAT, 1))

	return s


static func _part(id: StringName, slot: StringName, channels: int) -> DotAvatarPart:
	var p := DotAvatarPart.new()
	p.id = id
	p.slot = slot
	p.display_name = String(id).capitalize()
	p.colour_channels = channels
	# Free and shipped in the build: no content id, so the catalogue resolves it
	# straight to res://avatars/<id>.tscn without asking dot-cloud.
	p.free = true
	return p


## The catalogue that finds the stock parts, and any delivered ones through dot-cloud.
static func catalogue() -> DotAvatarCatalogue:
	var c := DotAvatarCatalogue.new()
	c.builtin_prefix = "res://avatars/"
	c.builtin_suffix = ".tscn"
	return c


## A stock avatar for a player with none of their own.
##
## Deterministic in the id, so the same player is the same character everywhere.
static func stock_avatar(player_id: StringName) -> DotAvatar:
	var seed_value := hash(String(player_id))
	var avatar := DotAvatar.make(SCHEMA_ID)

	avatar.set_part(SLOT_BODY, BODIES[seed_value % BODIES.size()])
	avatar.set_part(SLOT_HEAD, HEADS[(seed_value / 7) % HEADS.size()])

	# Every third player gets a hat, so a crowd is not a row of identical heads.
	if seed_value % 3 == 0:
		avatar.set_part(SLOT_HAT, HATS[(seed_value / 13) % HATS.size()])

	var body_colour := PALETTE[seed_value % PALETTE.size()]
	var head_colour := body_colour.lightened(0.35)

	avatar.set_colour(SLOT_BODY, 0, body_colour)
	avatar.set_colour(SLOT_HEAD, 0, head_colour)

	if avatar.has_slot(SLOT_HAT):
		avatar.set_colour(SLOT_HAT, 0, PALETTE[(seed_value / 3) % PALETTE.size()])

	return avatar


## Applies an avatar to a rig. Returns how many slots were drawn.
##
## [param avatar] may be a player's own document or a stock one; the builder does
## not care. A document that fails to conform to the schema — a part from a newer
## client, a slot this build does not have — is conformed rather than refused, so a
## player is never invisible because their hat is from the future.
static func apply(
	avatar: DotAvatar,
	rig: Node3D,
	p_schema: DotAvatarSchema,
	p_catalogue: DotAvatarCatalogue
) -> DotResult:
	if avatar == null or rig == null or p_schema == null:
		return DotResult.fail(DotError.CODE_INVALID, "Nothing to build.")

	# conform() edits the document IN PLACE and returns what it changed, not a new
	# document — so it is run on a copy, or a player's own avatar would be quietly
	# rewritten by the server that could not draw part of it.
	var document := avatar.duplicate_avatar()
	var conformed := p_schema.conform(document, null)

	if not conformed.ok:
		return conformed.wrap("The avatar could not be conformed to the schema.")

	var steps := DotAvatarBuilder.plan(document, p_schema, p_catalogue)

	return DotAvatarBuilder.apply(steps, rig, null)
