extends Node

const G2GBrowser := preload("g2g_browser.gd")

## The server browser: dot-browser's client half, for a records community.
##
## [b]dot-server has answered queries since it was written and nothing had ever asked
## one.[/b] `G2GQuery` has contributed the map, the tick rate, the styles and the
## world record since the module was written, and until this file existed the only
## thing that could read any of it was a test. That is the family's own "produced
## correctly and consumed by nobody" with the ends swapped.
##
## [b]There is no screen here, and game-arena has one.[/b] That game has a
## [DotScreenStack]; this client has a HUD and a keyboard, and the genre's answer to
## "show me the servers" is a chat command — `!servers` — because that is what a bhop
## player's fingers already do. The list model, the sources, the filters and the
## favourites are the same addon doing the same work; what differs is where it is
## drawn, which is the half a game is supposed to decide.
##
## [b]What a records player filters on is not what an arena player filters on.[/b] The
## default sort is PLAYERS and the default filter hides nothing, because on a timer
## server an empty one is often exactly what you want — you cannot set a record in a
## queue, and the map is the point rather than the people.
##
## [codeblock]
## var servers := G2GBrowser.new()
## add_child(servers)
## servers.setup()
## servers.add("bhop.example.com:27015", 27016)
## await servers.refresh()
## [/codeblock]

const CHANNEL := "g2g.browser"

signal listing_changed()

@export_group("Querying")

@export_range(1, 64, 1) var concurrency: int = 8

@export_range(200, 15000, 100) var timeout_ms: int = 2500

@export_group("Favourites")

@export var favourites_path: String = "user://g2gfast/servers.json"

var browser: DotBrowser = null
var filter: DotBrowserFilter = null

var _started: bool = false


func setup() -> DotResult:
	if _started:
		return DotResult.success(self)

	browser = DotBrowser.new()
	browser.name = "Browser"
	browser.concurrency = concurrency
	browser.timeout_ms = timeout_ms
	browser.retries = 1
	# The game section is why `G2GQuery` exists. `info.map` is dot-server's and means
	# "the content id of the loaded game", which on a server that never switches games
	# is empty; the map a player wants — `bhop_g2g_stages` — is the game's own fact and
	# arrives nested under `rules["game"]` so it cannot overwrite the other.
	browser.sections = PackedStringArray(["info", "players", "game"])
	browser.conditional = true
	browser.favourites_path = favourites_path
	browser.register_as = DotBrowser.SERVICE
	add_child(browser)

	var started := browser.start()

	if not started.ok:
		return started.wrap("The server browser could not start")

	filter = DotBrowserFilter.new()
	filter.online_only = true
	# Players, and nothing hidden. On a timer server an empty server is often exactly
	# what you want: you cannot set a record in a queue, and the map is the point.
	filter.sort = DotBrowserFilter.Sort.PLAYERS
	filter.hide_empty = false
	filter.favourites_first = true
	browser.filter = filter

	browser.refresh_finished.connect(
		func(_online: int, _total: int) -> void: listing_changed.emit()
	)

	var loaded := browser.load_favourites()
	DotLog.info(CHANNEL, "the server browser is up", {"favourites": loaded})

	_started = true
	return DotResult.success(self)


## Adds a server. The query port is a separate argument, never a third part of the
## string: `DotBrowserTarget.parse` takes `host:port`, and a three-part address parses
## as a malformed IPv6 one and fails several layers down at `connect_to_host`.
func add(address: String, query_port: int = 0) -> DotResult:
	if browser == null:
		return DotResult.fail(DotError.CODE_STATE, "The browser is not up.")

	var parsed := DotBrowserTarget.parse(address, 27015)

	if not parsed.ok:
		return parsed

	var target := parsed.value as DotBrowserTarget

	if query_port > 0:
		target.query_port = query_port

	var entry := browser.add_target(target)
	listing_changed.emit()

	return DotResult.success(entry)


func refresh() -> DotResult:
	if browser == null:
		return DotResult.fail(DotError.CODE_STATE, "The browser is not up.")

	var res: DotResult = await browser.refresh()
	return res


func listing() -> Array[DotBrowserEntry]:
	return browser.filtered() if browser != null else []


## What the game says about itself, from the query's `game` section.
##
## Not `entry.map`. See the note in [method setup] — the two mean different things and
## the one a player wants is the game's.
static func game_field(
	entry: DotBrowserEntry, key: String, fallback: String = ""
) -> String:
	if entry == null:
		return fallback

	var section: Variant = entry.rules.get("game")

	if not (section is Dictionary):
		return fallback

	return str((section as Dictionary).get(key, fallback))


## One line per server, the way a chat command wants them.
##
## [b]The world record is on the line, and that is this genre's whole browsing
## decision.[/b] A bhop player picking a server is picking a map and a board; the
## number that tells them whether it is worth joining is the time to beat, and
## `G2GQuery` puts it in the game section for exactly this.
func lines() -> PackedStringArray:
	var out := PackedStringArray()

	for entry in listing():
		out.append("%-24s %-20s %2d/%-2d %4dms%s" % [
			entry.name.substr(0, 24),
			G2GBrowser.game_field(entry, "map", entry.map).substr(0, 20),
			entry.players,
			entry.max_players,
			entry.ping_ms,
			G2GBrowser.record_line(entry),
		])

	if out.is_empty():
		out.append("No servers. Add one with !servers add <host:port>.")

	return out


## A number from the query's `game` section.
##
## [b]A separate accessor from [method game_field], because JSON has one number
## type.[/b] `G2GQuery` contributes `tick_rate` as an int and it comes back as a
## float — so `game_field(entry, "tick_rate")` is `"100.0"` and comparing it to
## `str(100)` fails. A reader that guesses the type of a field is a reader that gets
## it wrong once, and this is the once.
static func game_number(
	entry: DotBrowserEntry, key: String, fallback: float = 0.0
) -> float:
	if entry == null:
		return fallback

	var section: Variant = entry.rules.get("game")

	if not (section is Dictionary):
		return fallback

	var raw: Variant = (section as Dictionary).get(key)

	return float(raw) if raw is float or raw is int else fallback


## The server record, formatted, or empty when there is none.
##
## [b]`wr` is a dictionary, not a string.[/b] `G2GQuery` contributes
## `{"time": float, "by": String}` — a time and who set it — and `game_field` would
## `str()` the whole dictionary onto the end of a browser row. A field whose type a
## reader guesses is a field a reader gets wrong once.
static func record_line(entry: DotBrowserEntry) -> String:
	if entry == null:
		return ""

	var section: Variant = entry.rules.get("game")

	if not (section is Dictionary):
		return ""

	var wr: Variant = (section as Dictionary).get("wr")

	if not (wr is Dictionary):
		return ""

	var row: Dictionary = wr

	return "  WR %s by %s" % [
		DotTimerRun.format_time(float(row.get("time", 0.0))),
		str(row.get("by", "?")),
	]


func favourite(key: String, on: bool) -> void:
	if browser == null:
		return

	if on:
		browser.favourite(key)
	else:
		browser.unfavourite(key)

	listing_changed.emit()


func note_connected(key: String) -> void:
	if browser != null:
		browser.note_connected(key)


func describe_lines() -> PackedStringArray:
	return browser.describe_lines() if browser != null else PackedStringArray()
