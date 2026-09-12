extends Node

## Settings, audio, effects, the console and the practice session.
##
## [codeblock]
## godot --headless --path . res://examples/headless_presentation.tscn
## [/codeblock]
##
## [b]Nearly every check here is about this game refusing something the other four
## accept[/b], because that is what the integration is: the same five addons, and a timer
## server's answer to each of them.
##
## Exits non-zero on any failure.

const CHECKS := 51

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-g2gfast: the presentation layer")

	_test_a_runner_is_not_shaken()
	_test_the_sounds_are_the_run()
	_test_the_landing_is_a_speedometer()
	_test_console_is_prefixed()
	_test_a_party_run_is_tainted()
	_test_chat_box()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for f in _failures:
		print("  %s" % f)
	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _make() -> G2GPresentation:
	var p := G2GPresentation.new()
	p.name = "P%d" % _entered
	add_child(p)
	p.setup()
	# A memory store. A suite that writes to `user://` is one whose result depends on
	# what the last run left there -- which this family already shipped once, as a
	# dedicated suite that began failing on its ninth run.
	p.settings.local_store = DotSettingsStoreMemory.new()
	p.settings.load_now()
	p.apply_all()
	return p


# --- 1 ----------------------------------------------------------------------

func _test_a_runner_is_not_shaken() -> void:
	_section("A shaken camera on a surf ramp is a lost run")

	var s := G2GPresentation.schema()
	_check(s.validate().ok, "the schema validates")

	# The disagreement with every other game in the family, and it is a default rather
	# than an absence: a player doing deathmatch on the same server can turn it on.
	_check(
		is_equal_approx(float(s.find(&"shake_scale").default_value), 0.0),
		"camera shake defaults to OFF here, where every other game defaults it to on"
	)
	_check(
		not bool(s.find(&"allow_flashes").default_value),
		"and so do full-screen flashes"
	)
	_check(
		s.find(&"shake_scale").max_value > 0.0,
		"while both are still settings, because the same server runs a deathmatch layer"
	)

	var p := _make()
	p.on_run_started(Vector3.ZERO)
	p.watch_movement(false, 900.0, Vector3.ZERO)
	p.watch_movement(true, 900.0, Vector3.ZERO)
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(
		p.camera_shake() == Vector3.ZERO,
		"so a landing at speed moves the camera by exactly nothing"
	)

	p.settings.set_value(&"shake_scale", 1.0)
	p.watch_movement(false, 900.0, Vector3.ZERO)
	p.watch_movement(true, 900.0, Vector3.ZERO)
	p.present(0.016, Vector3.ZERO, Vector3.FORWARD)
	_check(
		p.camera_shake() != Vector3.ZERO,
		"and a player who asked for it gets it"
	)

	# The one that matters for a timer: nothing the effects layer does may cost a tick.
	_check(
		p.fx.config.frame_budget <= 32,
		"the effect budget is small, because a frame here is a tick and a tick is 7.8 ms "
		+ "of somebody's run"
	)
	p.queue_free()
	_done()


# --- 2 ----------------------------------------------------------------------

func _test_the_sounds_are_the_run() -> void:
	_section("Four sounds that are the game, and none of them may be dropped")

	var p := _make()
	var cat := p.audio.catalogue

	for id in [&"timer_start", &"timer_split", &"timer_finish", &"personal_best"]:
		var d := cat.find(id)
		_check(d != null, "there is a sound for '%s'" % id)
		if d != null:
			_check(
				d.priority >= 100,
				"and it outranks everything, because it IS the game (%s)" % id
			)

	var sink := p.audio.sink as DotAudioSinkNull
	sink.forget()
	p.on_run_finished(Vector3.ZERO, false)
	_check(sink.count_of(&"timer_finish") == 1, "finishing makes a noise")
	_check(
		sink.count_of(&"personal_best") == 0,
		"and an ordinary finish is not a personal best"
	)

	sink.forget()
	p.fx.flash_colour.a = 0.0
	p.on_run_finished(Vector3.ZERO, true)
	_check(sink.count_of(&"personal_best") == 1, "a personal best is its own sound")
	_check(
		is_equal_approx(p.fx.flash_colour.a, 0.0),
		"and does not tint the screen, because flashes are off here unless asked for"
	)

	p.queue_free()
	_done()


# --- 3 ----------------------------------------------------------------------

func _test_the_landing_is_a_speedometer() -> void:
	_section("A landing sounds like how fast you were going")

	var p := _make()
	var sink := p.audio.sink as DotAudioSinkNull
	p.audio.listener_position = Vector3.ZERO

	sink.forget()
	p.watch_movement(false, 300.0, Vector3.ZERO)
	p.watch_movement(true, 300.0, Vector3.ZERO)
	# Typed explicitly. Indexing a Dictionary yields a Variant, and `var x := <Variant>`
	# is a parse ERROR under these projects' settings -- which makes the SCENE fail to
	# load, and a scene that fails to load HANGS rather than failing, because nothing ever
	# reaches get_tree().quit(). That is in this family's own list of hazards and it cost
	# two timed-out runs here for want of running the check pass first.
	var slow: float = float(sink.played()[sink.played().size() - 1]["pitch"])

	OS.delay_msec(70)
	sink.forget()
	p.watch_movement(false, 1600.0, Vector3.ZERO)
	p.watch_movement(true, 1600.0, Vector3.ZERO)
	var fast: float = float(sink.played()[sink.played().size() - 1]["pitch"])

	_check(
		fast > slow,
		"landing at 1600 is higher than landing at 300 (%.2f against %.2f), which is the "
		% [fast, slow]
		+ "cheapest speedometer there is"
	)

	# Watched rather than listened for: a client that hooked the authority's signal would
	# be silent online and perfectly noisy offline.
	OS.delay_msec(70)
	sink.forget()
	p.watch_movement(true, 900.0, Vector3.ZERO)
	_check(
		sink.count_of(&"land") == 0,
		"and staying on the ground is not a landing, because it is the EDGE that is heard"
	)

	p.queue_free()
	_done()


# --- 4 ----------------------------------------------------------------------

func _test_console_is_prefixed() -> void:
	_section("Two consoles whose names mean opposite things")

	var p := _make()
	_check(p.console != null and p.console_panel != null, "there is a console and a panel")

	var missing := PackedStringArray()
	for key in G2GPresentation.schema().keys():
		if not p.console.all_names().has(String(key)):
			missing.append(String(key))
	_check(missing.is_empty(), "every setting is reachable (%s)" % ", ".join(missing))

	p.console.submit("sensitivity 4")
	_check(
		is_equal_approx(p.settings.get_float(&"sensitivity"), 4.0),
		"a console line writes the document"
	)
	_check(
		p.settings.schema.find(&"sensitivity").scope == DotSettingsDef.Scope.ACCOUNT,
		"and a runner's sensitivity follows them, because it is months of muscle memory"
	)

	p.console.submit("rcon_password hunter2")
	_check(
		not p.console.buffer.to_text().contains("hunter2"),
		"a credential never reaches the scrollback"
	)

	# The server's console is added with a prefix here and unprefixed everywhere else,
	# because `!s3` means a local navigation on a client and a teleport that ends a run
	# on a server.
	var server_sources := 0
	for src in p.console.sources():
		if src.source_name() == "server":
			server_sources += 1
	_check(
		server_sources == 0,
		"with no server bridged in a client-only process, which is most of them"
	)

	p.queue_free()
	_done()


# --- 5 ----------------------------------------------------------------------

func _test_a_party_run_is_tainted() -> void:
	_section("A run nobody can vouch for is not a record")

	DotP2PSignallerLoopback.reset_all()

	var party := G2GParty.new()
	party.name = "Party"
	add_child(party)
	_check(party.setup().ok, "a party sets up")

	_check(
		party.session.config.trust == DotP2PConfig.Trust.SANDBOXED,
		"a practice session is sandboxed"
	)
	_check(
		not party.session.config.migrate_host,
		"and does not migrate, because a time made of two machines' clocks is worse than "
		+ "no time at all"
	)

	var run := DotTimerRun.new()
	_check(party.ranked(), "an ordinary session is ranked")
	_check(not party.taint_if_unranked(run), "so a run in it is untouched")
	_check(not run.tainted, "and stays clean")

	party.session._state = &"hosting"
	_check(not party.ranked(), "a live peer-to-peer session is not")
	_check(party.taint_if_unranked(run), "and a run started in it is tainted")
	_check(
		run.tainted,
		"using the field dot-timer has had since it was written, whose first caller was "
		+ "this game's effects layer for exactly the same reason"
	)

	# Tainted rather than refused: a run you cannot compare is still a run worth doing,
	# which is the choice this game already made about movement effects.
	_check(
		party.describe_lines().size() > 1,
		"and it says so when asked, rather than refusing the session outright"
	)

	party.queue_free()
	_done()


# --- 6 ----------------------------------------------------------------------

func _test_chat_box() -> void:
	_section("A runner who can be talked to and can talk back")

	var p := _make()
	var window := p.chat_window

	_check(window != null, "the client builds a chat box at all")

	if window == null:
		_done()
		return

	_check(
		DotInputBinding.describe_action(window.open_action) == "Y",
		"opened by Y, which is where this genre has put it for twenty-five years"
	)
	_check(window.enabled, "drawn by default, on a server that said nothing")

	p.set_chat_relayed(true)
	_check(not window.enabled, "auto takes it away when a relay is carrying chat")

	window.add_said("someone", "but you can still hear this")
	_check(
		window.line_count() > 0,
		"and the log still draws what other people said",
		"off means you type somewhere else, never that you are out of the conversation"
	)

	p.settings.set_value(&"chat_window", &"on")
	_check(window.enabled, "on keeps the box even with a relay running: both, if you want")

	p.settings.set_value(&"chat_window", &"off")
	_check(not window.enabled, "off never draws it")

	p.settings.set_value(&"chat_window", &"auto")
	p.set_chat_relayed(false)
	_check(window.enabled, "and auto gives it back")

	p.settings.set_value(&"chat_open_key", "T")
	_check(
		DotInputBinding.describe_action(window.open_action) == "T",
		"rebinding through the settings document moves the key"
	)
	_check(
		InputMap.action_get_events(window.open_action).size() == 1,
		"and leaves ONE binding, not the old one as well"
	)

	# [b]The one that costs a run.[/b] A client that keeps reading movement while somebody
	# types strafes them off a ramp, and on a timer server that is minutes of work gone.
	_check(not p.swallows_input(), "a closed box does not swallow input")
	window.open()
	_check(p.swallows_input(), "an open one does, so a typed key is not a strafe")
	window.close()
	_check(not p.swallows_input(), "and gives it back when it closes")

	_done()


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("   ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s" % what)
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
	return condition
