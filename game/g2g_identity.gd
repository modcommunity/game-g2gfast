class_name G2GIdentity
extends Node

## Who a player is: content delivery, a profile, an avatar, and one admission flow.
##
## [b]This game already had the avatar half and not the rest.[/b] `G2GAvatars` has
## described a schema and six stock parts since it was written, `G2GModule._avatar_for`
## has duck-typed its way to a platform module that nothing was loading, and
## `G2GRig.dress` has drawn whatever it was handed. What was missing is the thing that
## produces an avatar that is not a stock one: dot-user for the profile, dot-cloud for
## a delivered part, dot-platform to join them, and dot-auth to prove any of it.
##
## The chain, in the order it depends on itself:
##
## [codeblock]
## dot-cloud    downloads and mounts content. Registers `dot_cloud_client`.
## dot-auth     reports this server to its site listing.
## dot-user     the profile that follows a player between servers.
## dot-avatar   what they look like, over G2GAvatars' schema.
## dot-platform joins the three into ONE admission, as its own DotModule.
## [/codeblock]
##
## [b]dot-cloud is registered or it is not built at all.[/b] Four call sites in two
## other addons look it up under `dot_cloud_client` and every one of them treats an
## absent cloud as "this deployment ships its content in its build" — which is true
## for a server with no sources. A registered client that failed to start is a
## different thing: present, found, and unable to do anything.

const CHANNEL := "g2g.identity"

@export_group("Content")

@export var content_urls: PackedStringArray = PackedStringArray()

@export var content_dirs: PackedStringArray = PackedStringArray()

@export_group("Backbone")

@export var report_to_backbone: bool = false

## Where the backbone is. Empty uses [DotAuthConfig]'s own default.
##
## [b]A default endpoint is a security property, not a convenience.[/b] dot-auth once
## shipped a domain that was not the site and was registered to nobody, so every
## deployment that did not override it aimed the opening request of an authentication
## flow at a name any stranger could buy.
@export var backbone_url: String = ""

@export_group("Admission")

## Refuse a player whose profile could not be resolved.
##
## Off. An unreachable profile store is a reason to let somebody run as a guest, not a
## reason to leave them at a loading screen — and on a records server a guest's times
## still file under their session key.
@export var require_profile: bool = false

var cloud: DotCloudClient = null
var users: DotUserManager = null
var avatars: DotAvatarManager = null
var platform: DotPlatformHub = null
var backbone: DotBackboneClient = null


func setup() -> DotResult:
	var clouded: DotResult = await _build_cloud()

	if not clouded.ok:
		return clouded

	if report_to_backbone:
		var reached: DotResult = await _build_backbone()
		DotLog.result(CHANNEL, "the backbone client", reached)

	var usered: DotResult = await _build_users()

	if not usered.ok:
		return usered

	var avatared: DotResult = await _build_avatars()

	if not avatared.ok:
		return avatared

	var platformed: DotResult = await _build_platform()
	return platformed


func _build_cloud() -> DotResult:
	if content_urls.is_empty() and content_dirs.is_empty():
		# See the class note. `DotCloudClient.start` refuses when signing is required
		# and no trusted key is configured — correctly, because a client that mounts
		# unsigned content will mount anything a server sends it — and it says so with
		# a red line on every boot.
		DotLog.info(CHANNEL, "content ships in this build", {
			"reason": "no content sources are configured"
		})
		return DotResult.success(null)

	cloud = DotCloudClient.new()
	cloud.name = "Cloud"
	cloud.http_base_urls = content_urls
	cloud.local_search_dirs = content_dirs
	cloud.register_service = true
	add_child(cloud)

	var started: DotResult = await cloud.start()

	if not started.ok:
		DotLog.info(CHANNEL, "content delivery is off", {
			"why": started.error.message
		})

	return DotResult.success(cloud)


func _build_backbone() -> DotResult:
	var config := DotAuthConfig.new()

	if backbone_url != "":
		config.backbone_url = backbone_url

	backbone = DotBackboneClient.new()
	backbone.name = "Backbone"
	backbone.config = config
	backbone.auto_report = true
	add_child(backbone)

	var ready: DotResult = await backbone.start()
	return ready


func _build_users() -> DotResult:
	users = DotUserManager.new()
	users.name = "Users"
	users.register_service = true
	add_child(users)

	var ready: DotResult = await users.setup()
	return ready


func _build_avatars() -> DotResult:
	avatars = DotAvatarManager.new()
	avatars.name = "Avatars"
	# The game's own schema, not a second one. `G2GRig.dress` conforms every document
	# to it, so a manager validating against a different schema would accept avatars
	# the rig then silently rewrote.
	avatars.schema = G2GAvatars.schema()
	avatars.register_service = true
	add_child(avatars)

	var ready: DotResult = await avatars.setup()
	return ready


func _build_platform() -> DotResult:
	var config := DotPlatformConfig.new()
	config.require_profile = require_profile
	# Never. A player without an avatar gets a stock document that is a real avatar
	# over the same schema; refusing them would be refusing somebody for the colour of
	# a capsule.
	config.require_avatar = false
	config.apply_profile_name = true
	config.broadcast_avatar_changes = true

	platform = DotPlatformHub.new()
	platform.name = "Platform"
	platform.config = config
	platform.load_layered_config = false
	platform.register_service = true
	add_child(platform)

	var ready: DotResult = await platform.setup()
	return ready


## An avatar for a player, theirs if they have one and a stock one if not.
##
## Never null. `G2GModule._avatar_for` already asks the platform module and falls back
## to what the client published and then to the stock one; this is the same fallback
## from the other end, for a caller that has a key rather than a session.
func avatar_for(player_key: String) -> DotAvatar:
	if platform != null:
		var held := platform.player(player_key)

		if held != null and held.avatar != null:
			return held.avatar

	return G2GAvatars.stock_avatar(StringName(player_key))


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if platform != null:
		out.append_array(platform.describe_lines())

	if users != null:
		out.append_array(users.describe_lines())

	if avatars != null:
		out.append_array(avatars.describe_lines())

	return out


func describe() -> Dictionary:
	return {
		"cloud": cloud.describe() if cloud != null else {},
		"users": users.describe() if users != null else {},
		"avatars": avatars.describe() if avatars != null else {},
		"platform": platform.describe() if platform != null else {},
	}
