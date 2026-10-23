extends Node

const DrConfig := preload("../game/dr_config.gd")
const DrGame := preload("../game/dr_game.gd")
const DrPlayer := preload("../game/dr_player.gd")
const DrNetBridge := preload("../game/net/dr_net_bridge.gd")
const DrNetLink := preload("../game/net/dr_net_link.gd")

## The game as a deployed server runs it: a real [DotServer], booted from a config file, with
## the module loaded BY PATH the way an operator names it — so the netcode, the services, the
## cvars and the stand-ins are the ones a deployment gets, not a copy assembled for a test.
##
## [b]What neither of the other suites can reach.[/b] `headless_run` drives a world by hand and
## `headless_net` joins two halves with no server; this is the only place [DrModule] loads,
## [DotGameModule]'s order runs, a cvar is typed at a console and a round is played by
## nothing but the stand-ins the module seats itself.

const SECTIONS := 12
const CHECKS := 87

const SERVER_DIR := "user://dr_dedicated"
const PORT := 28931
const QUERY_PORT := 28932
const TICK_RATE := 60

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var server: DotServer = null
var game: DrGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("deathrun as a dedicated server")
	print("")

	var probe: Array = []
	if not _is_exit_probe():
		probe = await _run_exit_probe()

	DotPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()

	if server != null and server.state == DotServer.State.RUNNING:
		await _test_the_module_loads()
		_test_the_commands()
		await _test_a_round_runs()
		await _test_a_reload_keeps_delivered_courses()
		await _test_the_course_vote()
		_test_rotation_file()
		_test_finish_round_waits_for_a_live_round()
		await _test_a_covered_seat_is_not_harmed()
		await _test_it_unloads_cleanly()

	_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	# The copy of this suite that the exit probe runs does not run the probe itself.
	var sections := SECTIONS - (1 if _is_exit_probe() else 0)
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	if _sections_entered != _sections_finished or _sections_entered != sections:
		print("ERROR: %d of %d sections finished, %d declared." % [_sections_finished, _sections_entered, sections])
		code = 1

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, checks])
		code = 1

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)
	get_tree().quit(code)


## Takes the server down before quitting: a booted [DotServer]'s listener holds the main loop,
## and a run that only called `quit()` prints its results and hangs. See mg-smash-copter.
func _shut_down() -> void:
	if server == null:
		return

	if server.modules != null:
		server.modules.unload_all()

	server.shutdown("the dedicated test is finished")

	for _i in range(10):
		await get_tree().process_frame

	if is_instance_valid(game):
		remove_child(game)
		game.free()
		game = null

	if is_instance_valid(server):
		remove_child(server)
		server.free()
		server = null

	await get_tree().process_frame


func _boot() -> void:
	_section("booting")

	# `startup_config`, because `sv_tickrate` is startup-only and dot-server execs this file
	# before the listener for exactly that reason.
	var cfg_path := "%s/server.cfg" % SERVER_DIR
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)
	cfg.store_line("// written by examples/dedicated.gd")
	cfg.store_line("sv_tickrate %d" % TICK_RATE)
	cfg.close()

	var config := DotServerConfig.new()
	config.startup_config = cfg_path
	config.autoexec_config = ""
	config.hostname = "deathrun test"
	config.max_players = 24
	config.hibernate_when_empty = false
	config.rcon_password = ""
	config.port = PORT
	config.query_port = QUERY_PORT
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	# Off, or this run never ends: a thread blocked in a read of stdin is one Godot will not
	# exit without.
	config.stdin_console_enabled = false

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)

	for _i in range(120):
		await get_tree().process_frame

		if server.state == DotServer.State.RUNNING:
			break

	_check(server.state == DotServer.State.RUNNING, "the server boots", DotServer.State.keys()[server.state])
	_check(Engine.physics_ticks_per_second == TICK_RATE, "and sv_tickrate reached the engine",
		"%d" % Engine.physics_ticks_per_second)
	_finished()


func _test_the_module_loads() -> void:
	_section("the module")

	# The world is built after the server (whose tick rate it reads) and before the module
	# (which refuses to load without a world to run; it cannot build one).
	var config := DrConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.round_seconds = 30.0
	config.minimum_players = 3
	config.course_ids = PackedStringArray(["dr_practice"])

	game = DrGame.new()
	game.name = "World"
	game.config = config
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	await get_tree().process_frame

	_check(DotRegistry.get_node_service(DrGame.SERVICE) == game, "the world publishes itself where a module looks")
	_check(not game.stage.doc.is_empty(), "and already has a course")

	(load("res://game/dr_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % SERVER_DIR)
	var loaded: DotResult = await server.modules.load_module("res://game/dr_module.gd")
	_check(loaded.ok, "the module loads into the server", loaded.error.message if not loaded.ok else "")

	var module := _module()
	_check(module != null and module.get("net") != null and module.get("bridge") != null,
		"with its netcode and the game's bridge")

	var net: DotNetManager = module.get("net") if module != null else null
	_check(net != null and net.config.tick_rate == TICK_RATE, "the netcode runs at the configured rate")
	_check(net != null and absf(net.config.world_extent - DrGame.NET_WORLD_EXTENT) < 0.01,
		"against the world extent both ends decode with")
	_finished()


func _test_the_commands() -> void:
	_section("the console")
	_check(_said(_run_command("dr_status"), "deathrun"), "dr_status says what the round is doing")
	_check(_said(_run_command("dr_courses"), "dr_practice"), "dr_courses lists the courses")
	_check(_said(_run_command("dr_traps"), "Trapdoor"), "dr_traps lists this course's traps")
	_check(_said(_run_command("dr_net"), "bridge"), "dr_net says what the netcode is doing")

	# A cvar's default is the value the world was built with, and setting one writes through.
	_check(_said(_run_command("dr_round_seconds"), "30"), "dr_round_seconds reports the world's own value")
	var _set := _run_command("dr_round_seconds 45")
	_check(is_equal_approx(game.config.round_seconds, 45.0), "and setting it writes through to the world",
		"%.1f" % game.config.round_seconds)
	var _back := _run_command("dr_max_activators 0")
	_check(game.config.max_activators == 1, "a round with no activator is not one: it is taken as one",
		"%d" % game.config.max_activators)
	# And it is REPLICATED: dot-server sends it to every client before its scene loads and on
	# every change, so a client's own combat manager (following its link) predicts tracers
	# under the server's level rather than its default.
	var shared := server.console.find_cvar("mp_teammate_passthrough")
	var _two := _run_command("mp_teammate_passthrough 2")
	_check(shared != null and shared.has_flag(DotConVar.FLAG_REPLICATED)
			and server.console.replicated_values().get("mp_teammate_passthrough", "") == "2",
		"mp_teammate_passthrough is replicated: a client is sent the server's level",
		str(server.console.replicated_values()))
	var _one := _run_command("mp_teammate_passthrough 1")
	_finished()


## A whole round, played by the stand-ins the module seats on its own.
func _test_a_round_runs() -> void:
	_section("a round, played by the stand-ins")
	var rounds: Array = []
	game.round_over.connect(func(n: int, winner: int, why: String) -> void: rounds.append([n, winner, why]))

	# Real time: the server ticks itself. The module tops the server up every two seconds. A
	# round is at most forty-five seconds here, and the stand-ins end most of them far sooner:
	# an activator pressing on runners, or a runner reaching the end and putting it down.
	var until := Time.get_ticks_msec() + 60000

	while Time.get_ticks_msec() < until and rounds.is_empty():
		await get_tree().physics_frame

	var bots := 0

	for id: StringName in game.players:
		if (game.players[id] as DrPlayer).is_bot:
			bots += 1

	_check(bots == game.config.minimum_players, "the module seated stand-ins up to the minimum", "%d" % bots)
	_check(game.players_on(DrGame.ACTIVATORS).size() == 1, "and drew one of them to the buttons")
	_check(not rounds.is_empty(), "and a round was decided", str(rounds))
	_check(not rounds.is_empty() and str(rounds[0][2]) != "", "with a sentence saying why", str(rounds))
	# [b]A person takes a stand-in's place, and leaving gives it back[/b]: DotBotQuota's fill
	# mode, the family's default. Driven by calling the roster check rather than waiting for
	# its interval, with a person added through the bridge the way a test's player is (peer
	# zero, not a stand-in), so the count is exact and nothing else moves under it.
	var quota_module := _module()
	var quota_bridge: Object = quota_module.get("bridge") if quota_module != null else null
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota_mode") != null,
		"the shared bot_quota cvars are registered")
	var picked := _run_command("bot_difficulty hard")
	var bots_skill := DotBotSettings.of(quota_module.get("game")) if quota_module != null else null
	_check(bots_skill != null and bots_skill.difficulty() == "hard", "bot_difficulty is a cvar, and reaches the world the stand-ins play from", str(picked))
	var _spread := _run_command("dr_bot_spread 3")
	_check(bots_skill != null and is_equal_approx(bots_skill.profile.aim_error, 3.0), "and the old dr_bot_spread sets bot_aim_error")
	var _reset := _run_command("bot_settings_reset")
	var _medium := _run_command("bot_difficulty medium")
	var _alias := _run_command("dr_min_players 3")
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota").get_int() == 3,
		"and the old dr_min_players sets bot_quota",
		server.console.find_cvar("bot_quota").get_string() if server.console.find_cvar("bot_quota") != null else "missing")

	if quota_module != null and quota_bridge != null:
		quota_module.call("_keep_the_round_full")
		var bots_before: int = (quota_module.get("_bot_ids") as Array).size()
		var joined: DotResult = quota_bridge.call("add_player", 0, 9001, "Person")
		quota_module.call("_keep_the_round_full")
		var bots_with: int = (quota_module.get("_bot_ids") as Array).size()
		_check(joined.ok and bots_before == 3 and bots_with == bots_before - 1,
			"a person joining takes a stand-in's place", "%d -> %d" % [bots_before, bots_with])
		quota_bridge.call("remove_player", 9001)
		quota_module.call("_keep_the_round_full")
		var bots_after: int = (quota_module.get("_bot_ids") as Array).size()
		_check(bots_after == bots_before, "and a stand-in comes back when they leave",
			"%d -> %d" % [bots_with, bots_after])
		# Named from the game's list through dot-bot, never "Stand-in 2", never twice.
		var names: Array = []
		for id: StringName in quota_module.get("_bot_ids"):
			names.append((game.players[id] as DrPlayer).display_name)
		var distinct := {}
		for n in names:
			distinct[n] = true
		_check(distinct.size() == names.size() and names.all(func(n: String) -> bool: return DrGame.BOT_NAMES.has(n)),
			"the stand-ins have names from the list, none shared", str(names))
	else:
		_check(false, "a person joining takes a stand-in's place", "no module")
		_check(false, "and a stand-in comes back when they leave", "no module")
		_check(false, "the stand-ins have names from the list, none shared", "no module")

	var _restored := _run_command("dr_min_players 3")

	_check(_said(_run_command("dr_status"), "round"), "and dr_status still answers")
	_finished()


## The players' vote decides the next course: a ballot over the server's courses, one vote
## cast, and the round's end puts the winner on the next round. Driven by hand rather than by
## the clock, because stand-ins are not voters and a server of stand-ins never opens one.
func _test_the_course_vote() -> void:
	_section("the course vote")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(vote != null, "the module built a course vote")

	if vote == null:
		_finished()
		return

	_check(server.console.find_command("vote") != null if server.console.has_method("find_command") else true,
		"and registered dot-vote's vote command")

	# Hibernation: DotGameModule hands the director the server, the ballot's timer waits with
	# it, and waking starts both again from the top.
	var sleeper: DotVoteDirector = vote.get("director")
	_check(server.hibernation_changed.is_connected(sleeper.set_hibernating),
		"the vote follows the server's hibernation without a line of this game's")
	vote.set("_opened_this_course", true)
	server.console.execute("sv_hibernate_when_empty 1")
	_check(server.is_hibernating() and sleeper.hibernating, "an empty server sleeps, and the vote with it",
		server.state_name())
	var on_course: float = vote.get("_on_course_sec")
	vote.call("advance", 600.0)
	_check(is_equal_approx(vote.get("_on_course_sec"), on_course), "ten minutes asleep do not count towards the ballot")
	server.console.execute("sv_hibernate_when_empty 0")
	_check(not sleeper.hibernating, "waking wakes the vote")
	_check(is_zero_approx(vote.get("_on_course_sec")) and not vote.get("_opened_this_course"),
		"and the course ballot is owed again from the top")

	# Every course in the directory, not only this suite's practice course.
	game.config.course_ids = PackedStringArray()
	vote.call("refresh_courses")
	var ids: Array = []

	for choice: DotVoteChoice in (vote.get("source") as DotVoteListSource).entries:
		ids.append(String(choice.id))

	_check(ids.has("dr_ice_works") and ids.has("dr_foundry"), "it offers the delivered courses", str(ids))

	# The map menu's server half (M): the owner's flag changes the course now, anybody else
	# gets a nomination and a rock-the-vote. Contexts as dot-server makes them for a chat line.
	var menu_half: Object = vote.get("commands").get("map_menu")
	_check(menu_half != null and server.console.find_command("mapmenu") != null
		and server.console.find_cvar("sv_map_menu_flag").get_string() == "generic"
		and (menu_half.get("change_fn") as Callable).is_valid(),
		"the map menu is there, staff-only by default, changing the course now")
	var staff := DotCmdContext.new()
	staff.source = DotCmdContext.Source.CHAT
	staff.permissions = PackedStringArray(["generic"])
	var player := DotCmdContext.new()
	player.source = DotCmdContext.Source.CHAT
	var offered: Dictionary = menu_half.call("offer", player)
	_check((offered["maps"] as Array).size() > 1 and not bool(offered["allowed"]) and bool(offered["vote"]),
		"a player is offered every course, as a vote")
	var target: StringName = &""
	for row: Dictionary in offered["maps"]:
		if not bool(row["current"]):
			target = StringName(str(row["id"]))
			break
	var changed: Dictionary = await menu_half.call("choose", staff, target)
	_check(bool(changed["ok"]) and game.stage.id() == target, "staff choosing one changes the course on the spot",
		"%s: %s" % [target, changed.get("text", "")])

	# Not the course just chosen: a ballot for the course that is playing changes nothing, and with more courses
	# delivered the first one offered can be dr_foundry itself.
	# The ballot holds at most max_options of the delivered courses, so vote for one that is on it.
	var picked: Array = []  # a lambda cannot assign a captured local
	vote.set("voters_fn", func() -> Array: return [&"7"])
	var director: DotVoteDirector = vote.get("director")
	director.vote_opened.connect(func(options: Array, _seconds: float) -> void:
		for o: Variant in options:
			if StringName(str(o)) != game.stage.id():
				picked.append(StringName(str(o)))
				break)
	var opened := director.open_vote(DotVoteClock.REASON_MANUAL)
	_check(opened.ok and director.is_voting(), "a ballot opens", opened.error.message if not opened.ok else "")

	var voted: StringName = picked[0] if not picked.is_empty() else &""
	var cast := director.cast_one(&"7", voted)
	# Everybody has voted; the director closes on its next advance, which is the server's tick.
	director.advance(0.05)
	_check(cast.ok and director.pending_id() == voted, "one vote decides it, waiting for the round's end",
		"%s %s [%s] %s" % [cast.ok, director.pending_id(), voted, cast.error.message if not cast.ok else ""])

	# No frame between these: the stand-ins' rounds are still running, and one that started in
	# between would lay the voted course itself and leave this check reading the rotation's.
	vote.call("note_round_end")
	_check(game.next_course_id == voted, "the round's end hands it to the world", str(game.next_course_id))

	game.call("_lay_out_course")
	_check(game.stage.id() == voted and game.next_course_id == &"",
		"and the next course laid is the one voted for, once", "%s / %s" % [game.stage.id(), game.next_course_id])

	# Rock the vote, typed at the console as a player's !rtv reaches it. Under MANUAL the
	# director opens nothing itself, a passed rtv included: it answered "Rocked. 1 of 1." and
	# no ballot came. Past dot-vote's cooldown between two ballots, on the director alone so
	# the course's own ballot timer does not open one first.
	_check(director.current_id() == voted and not director.is_voting(),
		"the new course starts the vote over", str(director.current_id()))
	vote.set("voters_fn", func() -> Array: return [&"console"])
	director.rules.rtv_delay_sec = 0.0
	director.rules.min_players_to_vote = 1
	director.rules.rtv_min_players = 1
	director.rules.allow_single_voter_auto = true
	director.advance(director.rules.vote_cooldown_sec + 0.1)
	var ballots: Array = []
	director.vote_opened.connect(func(_options: Array, _seconds: float) -> void: ballots.append(1))
	var rocked := _run_command("rtv")
	vote.call("advance", 0.05)
	_check(director.is_voting(), "and a passing rock-the-vote opens a ballot", str(rocked))
	# The director opens a rocked ballot itself (dot-vote API 2); this game no longer does, so
	# exactly one ballot opens, not one from each.
	_check(ballots.size() == 1, "and exactly one ballot, the director's alone", str(ballots.size()))
	_finished()


## [b]`time_up: finish_round` waits for a round being played, never for warmup.[/b] The game
## hands dot-vote its match's answer (`round_in_progress_fn`); without it a limit that ran out
## in warmup held the change for `finish_round_max_sec` over a round that had not started.
## Run on a director of its own carrying the game's own hook, so the real vote's clock is
## untouched; the match's state is set by hand and put back.
func _test_finish_round_waits_for_a_live_round() -> void:
	_section("finish_round waits for a live round, not warmup")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	var director: DotVoteDirector = vote.get("director") if vote != null else null
	var hook: Variant = director.get("round_in_progress_fn") if director != null else null
	_check(hook is Callable and (hook as Callable).is_valid(), "the game tells its vote whether a round is live")

	if not (hook is Callable and (hook as Callable).is_valid()) or game == null or game.match_node == null:
		_finished()
		return

	var match_node: DotMatch = game.match_node
	var was := match_node.state
	match_node.state = DotMatch.State.WARMUP
	var warm_applied := []
	var warm := _finish_round_probe(hook, warm_applied)
	_check(warm_applied == [&"b"] and not warm.is_finishing_round(),
		"in warmup a time limit with finish_round changes at once", str(warm_applied))

	match_node.state = DotMatch.State.LIVE
	var live_applied := []
	var live := _finish_round_probe(hook, live_applied)
	_check(live_applied.is_empty() and live.is_finishing_round(),
		"during a live round it waits for the round", str(live_applied))

	match_node.state = DotMatch.State.INTERMISSION
	live.advance(0.1)
	_check(live_applied == [&"b"], "and the round ending is the change", str(live_applied))

	match_node.state = was
	warm.queue_free()
	live.queue_free()
	_finished()


## A director under `time_up: finish_round` carrying [param hook], its clock run out with a
## winner already decided: what dot-vote's own suite builds, with the game's answer in it.
func _finish_round_probe(hook: Callable, applied: Array) -> DotVoteDirector:
	var source := DotVoteListSource.new()
	var _a := source.add(DotVoteChoice.of(&"a", "A"))
	var _b := source.add(DotVoteChoice.of(&"b", "B"))
	source.apply_fn = func(id: StringName) -> DotResult:
		applied.append(id)
		return DotResult.success(id)

	var rules := DotVoteRules.new()
	rules.apply_delay_sec = 0.0
	rules.duration_sec = 100.0
	rules.vote_lead_sec = 40.0
	rules.vote_duration_sec = 5.0
	rules.include_extend = false
	rules.apply = DotVoteRules.Apply.END_OF_TIME
	rules.cooldown = 0
	rules.time_up = DotVoteRules.TimeUp.FINISH_ROUND
	# For ever: only the hook may release it.
	rules.finish_round_max_sec = 0.0

	var probe := DotVoteDirector.new()
	probe.rules = rules
	probe.source = source
	probe.register_service = false
	probe.self_advance = false
	probe.round_based = true
	probe.player_count_fn = func() -> int: return 4
	probe.set(&"round_in_progress_fn", hook)
	add_child(probe)
	probe.begin(&"a")
	source.current = &"a"

	for i in range(61):
		probe.advance(1.0)

	probe.cast_one(&"p1", &"b")

	# The ballot closes, then the limit (100 s) runs out with the winner decided.
	for i in range(46):
		probe.advance(1.0)

	return probe


## A reload keeps the courses the server names. `dr_reload` reads the course directory again with
## `load_from`, which forgets everything read before, and in two of the three games built this
## way it stopped there: every delivered course was gone until a restart, with nothing logged.
## A pack "mounted" on the disk and a descriptor naming it stand in for dot-cloud and the
## deployment's map config (dot-server-deploy's cfg/content.yml), which a suite has neither of.
func _test_a_reload_keeps_delivered_courses() -> void:
	_section("a reload keeps the courses the server names")
	var key := "dot-test/dr-delivered@1.0.0"
	var mount := DotGameContent.mount_of(key)
	var dir := mount.path_join("courses")
	var id := &"dr_delivered_check"
	DirAccess.make_dir_recursive_absolute(dir)
	var doc: Dictionary = game.catalogue.practice()
	doc["id"] = String(id)
	var file := FileAccess.open(dir.path_join("delivered_check.json"), FileAccess.WRITE)
	# Plain, the way a document on the disk is: the built-in one holds Vector3s, which JSON
	# writes as strings the reader refuses.
	file.store_string(JSON.stringify(load("res://game/dr_course_doc.gd").call("_to_plain", doc)))
	file.close()

	# The manager's running descriptor, named the way a deployment names it. Restored below:
	# `_current` is the manager's own, and nothing else in this suite should see the pack.
	var manager: Object = server.games
	var was: Variant = manager.get("_current")
	var named := DotGameDescriptor.new()
	named.maps = PackedStringArray([key])
	manager.set("_current", named)

	var _first := _run_command("dr_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(game.catalogue.courses.has(id), "a course the server names is in the catalogue after dr_reload",
		str(game.catalogue.courses.keys()))
	_check(game.catalogue.courses.has(&"dr_practice"),
		"beside the built-in one")

	# The ballot sees them from boot, not only after a reload: _game_load builds the vote
	# before the delivered courses arrive, and a list read then held only the practice course,
	# which never opens a ballot. A module loaded again with the pack named is a boot.
	# Unloaded and loaded rather than module_reload, which reloads the script under the
	# world's live instances and says so on stderr.
	# Every course, not only this suite's practice one, for the length of this check.
	var only := game.config.course_ids
	game.config.course_ids = PackedStringArray()
	# And as a boot finds it: the world outlives the module, and its catalogue still holds the
	# course from the dr_reload above, which a vote built at load would read without the fix.
	var _builtin := game.catalogue.load_from(game.config.course_directory)
	var _reloaded := _run_command("module_unload deathrun")
	_reloaded.append_array(_run_command("module_load res://game/dr_module.gd"))
	for _i in range(60):
		await get_tree().process_frame

		if _module() != null and _module().get("vote") != null:
			break
	var booted_vote: Node = _module().get("vote") if _module() != null else null
	var booted_ids: Array = []

	if booted_vote != null:
		for choice: DotVoteChoice in (booted_vote.get("source") as DotVoteListSource).entries:
			booted_ids.append(String(choice.id))

	_check(booted_ids.has(String(id)), "and on the ballot of a module that boots with it named, unrefreshed",
		"%s %s" % [_reloaded, booted_ids])
	game.config.course_ids = only

	manager.set("_current", was)
	var _second := _run_command("dr_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(not game.catalogue.courses.has(id), "and it came from the server's list: unnamed, a reload drops it")

	DirAccess.remove_absolute(dir.path_join("delivered_check.json"))
	var path := dir
	while path != "res://dot_cloud":
		DirAccess.remove_absolute(path)
		path = path.get_base_dir()
	DirAccess.remove_absolute("res://dot_cloud")
	_finished()


## [b]A seat whose client has not lifted its loading cover cannot be harmed, and can once it does[/b]
## (dot-game's "still loading"), over a real ENet socket. A client joins and says nothing, as one
## still loading its level; the world's damage path is then asked to kill it by a shot, by a trap
## and by the floor, and must refuse all of them. An admin's slay still passes, and the draw of
## activators leaves it for last. The client then sends `game.cover` on the wire and the same hit
## lands. Stand-ins never reach this: a bot is never loading.
func _test_a_covered_seat_is_not_harmed() -> void:
	_section("a client behind its loading cover is not harmed, and is once it lifts")

	var module := _module()
	var bridge := module.get("bridge") as DrNetBridge if module != null else null
	var side := Node.new()
	side.name = "CoverClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Covered"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	# RPC paths are relative to the multiplayer root, so the link must sit at the path the
	# server's does: "Dedicated/Server" under the root.
	var mirror := Node.new()
	mirror.name = "Dedicated"
	side.add_child(mirror)
	mirror.add_child(link)
	# The link retires whatever the game left under it when it signs on, so a sink for the
	# server's snapshots is put back at each phase change (a real game scene does this itself).
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(DrNetLink.NODE_NAME)) == null:
			var sink := DrNetLink.attached_to(link, null, false)
			sink.name = DrNetLink.NODE_NAME
			link.add_child(sink)
	attach.call()
	link.phase_changed.connect(attach)
	var spawned := [false]
	link.spawned.connect(func() -> void: spawned[0] = true)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var joined := await _until(func() -> bool:
		return spawned[0] or link.phase == DotClientLink.Phase.FAILED, 30.0)
	joined = joined and spawned[0]
	var peer := side.multiplayer.get_unique_id() if joined else 0
	var session := 0
	if bridge != null and joined:
		var _seated := await _until(func() -> bool: return bridge.player_for_peer(peer) != 0, 10.0)
		session = bridge.player_for_peer(peer)
	var key := DrNetBridge.player_key(session)
	var _there := await _until(func() -> bool: return game.players.has(key), 10.0)
	var victim: DrPlayer = game.players.get(key)
	_check(victim != null, "a client joins over the socket and is seated", "peer %d session %d" % [peer, session])

	if victim == null:
		for what in [
			"the server holds it as loading", "a lethal hit does nothing to it",
			"a trap's kill and the floor's leave it up", "an admin's slay still passes",
			"the draw leaves it for a stand-in", "its cover report crosses the wire",
			"and the same hit now lands",
		]:
			_check(false, what)
		link.disconnect_from_server("done")
		side.queue_free()
		_finished()
		return

	_check(bool(module.call("is_peer_loading", peer)) and not game.can_be_harmed(key),
		"the server holds it as loading from its spawn")

	victim.health.alive = true
	victim.health.health = victim.health.max_health
	victim.health.invulnerable = false
	victim.health.invulnerable_until_tick = -1
	var before := victim.health.health
	var hit := DotDamage.make(0, victim.entity_id, victim.health.max_health * 10.0, null)
	hit.tick = game._tick
	hit.context = {"why": &"shot"}
	var _applied: Variant = game.combat.apply_damage(hit)
	_check(victim.is_alive() and is_equal_approx(victim.health.health, before),
		"a lethal hit does nothing to it", "%s -> %s" % [before, victim.health.health])

	game._kill(victim, 0, DrGame.DIED_TRAP)
	game._kill(victim, -1, DrGame.DIED_FELL)
	_check(victim.is_alive(), "a trap's kill and the floor's leave it up")

	var slain: Variant = (module.get("services") as Object).call("_mod_hurt", StringName(str(session)), -1.0)
	_check(slain is DotResult and (slain as DotResult).ok and not victim.is_alive(),
		"an admin's slay still passes", str(slain))
	victim.health.alive = true
	victim.health.health = before

	var drawn := 0
	for _i in range(12):
		game._draw_sides()
		if game.sides.get(key, 0) == DrGame.ACTIVATORS:
			drawn += 1
	_check(drawn == 0, "the draw leaves it for a stand-in", "drawn %d of 12" % drawn)

	DotGameClient.report_cover(link, false)
	var lifted := await _until(func() -> bool: return not bool(module.call("is_peer_loading", peer)), 10.0)
	_check(lifted and game.can_be_harmed(key), "its cover report crosses the wire and ends the loading state")
	var after_lift := victim.health.health
	var late := DotDamage.make(0, victim.entity_id, 1.0, null)
	late.tick = game._tick
	late.context = {"why": &"late"}
	var _late_applied: Variant = game.combat.apply_damage(late)
	_check(victim.health.health < after_lift, "and the same hit now lands",
		"%s -> %s" % [after_lift, victim.health.health])

	link.disconnect_from_server("done")
	side.queue_free()
	_finished()


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _test_it_unloads_cleanly() -> void:
	_section("unloading")
	server.modules.unload_all()
	await get_tree().process_frame
	_check(_module() == null, "the module unloads")
	_check(server.console.find_command("dr_status") == null if server.console.has_method("find_command") else true,
		"and takes its commands with it")
	_check(is_instance_valid(game), "and leaves the world, which outlives it")
	_finished()


## No message script preloads itself: in mg-buses-from-hell that one line leaked the whole
## script graph at exit (8ed866c), and the leak is printed after `quit()`, where no assertion
## reaches. So the cause is checked, on the source.
func _test_no_message_preloads_itself() -> void:
	_section("exiting clean")
	var offenders := PackedStringArray()
	var dir := DirAccess.open("res://game/net")

	for file in dir.get_files():
		if not file.ends_with(".gd"):
			continue

		var source := FileAccess.get_file_as_string("res://game/net/" + file)

		if source.contains("extends DotNetMessage") and source.contains("preload(\"%s\")" % file):
			offenders.append(file)

	_check(offenders.is_empty(), "no message preloads itself", ", ".join(offenders))
	_finished()


## Stands in for the module a vote's commands are registered on, recording the names.
class CommandHost extends Node:
	var added: Dictionary = {}

	func add_command(full: String, fn: Callable, _help: String, _permission: String) -> Object:
		added[full] = fn
		return null


## `maps.yml` (dot_map tiers): which courses rotate. The format is dot-map's selftest's; this is what the GAME
## does with it: a course left out is installed and loadable and is never drawn, never on a
## ballot, never nominated, marked in the map list; a switch of rotation takes effect; a renamed
## command is registered; no file means every course.
func _test_rotation_file() -> void:
	_section("rotation file")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	var catalogue = game.catalogue
	var made: Array[StringName] = []
	var kept_ids: PackedStringArray = game.config.course_ids
	game.config.course_ids = PackedStringArray()

	for n in 4:
		var doc: Dictionary = catalogue.practice().duplicate(true)
		doc["id"] = "rot_%d" % n
		doc["name"] = "Rotation %d" % n
		var _added: bool = catalogue._add(doc, "rotation test")
		made.append(StringName("rot_%d" % n))

	catalogue._rebuild_order()
	var keep_a: Array = ["rot_0", "rot_1"]
	var keep_b: Array = ["rot_2", "rot_3"]

	var parsed := DotMapRotationFile.from_trees([{"defaults": {
		"rotation": "a",
		"rotations": {"a": {"maps": keep_a, "mode": "random"}, "b": {"maps": keep_b, "mode": "cycle"}},
		"commands": {"names": {"rtv": "rockit", "dr_courses": "courselist"}},
	}}], "mg-deathrun")
	_check(parsed.ok, "a rotation file parses", str(parsed.error))
	var shipped := DotMapRotationFile.find_layers("", "mg-deathrun")
	_check(not shipped.is_empty() and str(shipped[0]).ends_with("cfg/game/mg-deathrun/dot_map/maps.yml"), "the shipped maps.yml is the game tier file", str(shipped))
	var kept = catalogue.rotation_file
	catalogue.rotation_file = parsed.value
	catalogue.apply_rotation(game.config.course_ids)

	var drawn := {}
	for _i in 30:
		var doc: Dictionary = catalogue.next_course(game.config.course_ids, true, game.random.stream(&"course"), &"")
		drawn[String(doc["id"])] = true
		catalogue.note_played(StringName(str(doc["id"])))
	var strays := drawn.keys().filter(func(id: String) -> bool: return not keep_a.has(id))
	_check(not drawn.is_empty() and strays.is_empty(), "a course outside the rotation is never drawn", str(strays))
	_check(catalogue.courses.has(&"rot_2") and catalogue.playable_courses(game.config.course_ids).has(&"rot_2"),
		"and stays installed and loadable")
	_check(not catalogue.rotating(game.config.course_ids).has(&"rot_2"), "but is not what the rotation offers")

	if vote != null:
		vote.call("refresh_courses")
		var ballot: Array = []
		for choice in (vote.get("source") as DotVoteListSource).entries:
			ballot.append(String(choice.id))
		_check(ballot.has("rot_0") and not ballot.has("rot_2"), "never on a ballot", str(ballot))
		var refused := _run_command("nominate rot_2")
		_check(not _said(refused, "Nominated"), "refused by nominate", ", ".join(refused))
		var accepted := _run_command("nominate rot_0")
		# A ballot may be running from the section before, which refuses any nomination; what
		# matters is that a course in the rotation is known to nominate, an unlisted one is not.
		_check(not _said(accepted, "nothing called"), "while one in the rotation is known to it", ", ".join(accepted))
		var merged: Callable = (vote.get("source") as DotVoteListSource).get("in_rotation_fn") if "in_rotation_fn" in vote.get("source") else Callable()
		_check(merged.is_valid() and not bool(merged.call(&"rot_2")) and bool(merged.call(&"rot_0")),
			"and the pack maps dot-vote merges are filtered by the same file")
	else:
		_check(false, "never on a ballot", "no vote")
		_check(false, "refused by nominate", "no vote")
		_check(false, "while one in the rotation is known to it", "no vote")
		_check(false, "and the pack maps dot-vote merges are filtered by the same file", "no vote")

	var out_row: Dictionary = {}
	var in_row: Dictionary = {}
	for row: Dictionary in game.course_rows():
		if row["id"] == "rot_2":
			out_row = row
		elif row["id"] == "rot_0":
			in_row = row
	_check(not out_row.is_empty() and not bool(out_row["in_rotation"])
			and str(out_row["name"]).contains("not in rotation"), "the course list marks it")
	_check(not in_row.is_empty() and bool(in_row["in_rotation"])
			and not str(in_row["name"]).contains("not in rotation"), "and leaves the rotating ones alone")
	_check(game.change_course_now(&"rot_2").ok, "while an admin's course change still loads it",
		str(game.stage.id()))

	_check(catalogue.switch_rotation("b").ok
			and catalogue.rotating(game.config.course_ids) == ([&"rot_2", &"rot_3"] as Array[StringName]),
		"a rotation switch takes effect")
	_check(not catalogue.switch_rotation("nowhere").ok, "and an unknown rotation changes nothing")

	var seen: Array = []
	for _i in 4:
		var doc: Dictionary = catalogue.next_course(game.config.course_ids, true, null, &"")
		seen.append(String(doc["id"]))
		catalogue.note_played(StringName(str(doc["id"])))
	_check(seen[0] != seen[1] and seen[0] == seen[2] and seen[1] == seen[3]
			and keep_b.has(seen[0]) and keep_b.has(seen[1]), "a cycle walks the rotation in turn", str(seen))

	_check(game.command_names("dr_courses") == PackedStringArray(["courselist"])
			and game.command_names("dr_reload") == PackedStringArray(["dr_reload"]),
		"the game's own map command is renameable from the file")

	var host := CommandHost.new()
	var bound: DotResult = vote.call("install_commands", host) if vote != null else null
	_check(bound != null and bound.ok and host.added.has("rockit") and not host.added.has("rtv"),
		"and a renamed rtv is registered under its new name", ", ".join(host.added.keys().slice(0, 6)))
	host.free()

	# No file: every course rotates, as it always did.
	catalogue.rotation_file = null
	catalogue.apply_rotation(game.config.course_ids)
	_check(catalogue.rotating(game.config.course_ids) == catalogue.playable_courses(game.config.course_ids)
			and catalogue.in_rotation(&"rot_2"), "with no file every course is in the rotation")

	# Put the world back: the other suites share this catalogue.
	for id in made:
		var _gone: bool = catalogue.courses.erase(id)
	catalogue._rebuild_order()
	catalogue.rotation_file = kept
	catalogue.apply_rotation(game.config.course_ids)
	game.config.course_ids = kept_ids
	if vote != null:
		vote.call("refresh_courses")
	_finished()


func _module() -> DotModule:
	return server.modules.get_module("deathrun") if server != null and server.modules != null else null


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, context)
	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.findn(text) >= 0:
			return true

	return false


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)


# --- Exiting clean ----------------------------------------------------------------

## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3


## How long the copy may run before it is killed and this probe fails. A copy that is still
## running this long after it started is hung, and the likeliest reason is the one that says
## nothing at all: a scene whose script failed to parse never reaches `quit()` and prints
## nothing. `-- --exit-probe-seconds N` lowers it, which is how the deadline itself is armed —
## any N shorter than the suite takes is a copy that is still running when it expires.
const EXIT_PROBE_SECONDS := 300


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


func _exit_probe_seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return EXIT_PROBE_SECONDS


## Runs this same suite in a fresh process: `[exit code, its stdout, its stderr, whether it
## had to be killed, the seconds it was allowed]`.
##
## [b]A leak is reported after `quit()`, by the engine, where nothing in the process that
## leaked can read it.[/b] "N ObjectDB instances were leaked at exit" is printed once the
## scene tree is gone, so the only process that can check a run's exit is another one. On
## Godot 4.7.2 a script that names itself, loaded after its base, cuts the engine's exit
## teardown short and every script loaded before it is reported leaked — hundreds of lines
## a passing run printed for weeks, which is why this is a check now and not a warning.
##
## [b]First, before this run opens a port[/b], so the two never contend for a socket — and
## so this run is always the second one against the same `user://`, which is the other
## thing no single run can see.
##
## [b]Not `OS.execute`.[/b] That blocks until the copy exits, so a copy that hangs held this
## run for ever; and when the outer `timeout` then killed this run, the copy was left behind
## holding the suite's directory and port. So the copy is started, polled against a deadline
## and killed at it. Two deadlines, because Godot dies on SIGTERM without running a line of
## script — nothing in this process can clean up after it is killed:
##
## - coreutils `timeout` wraps the copy where it exists. It is an exec wrapper, not a shell,
##   and it outlives this process, so a copy orphaned by the outer `timeout` still dies on
##   time. Its exit status 124 is how its expiry is recognised.
## - this loop's own deadline, a little later, for a platform without it.
##
## `execute_with_pipe` rather than `create_process`, because the latter captures nothing and
## the whole point is reading what the copy printed. Non-blocking, and drained on every pass
## rather than once at the end: a pipe holds 64 KiB, and a copy that fills it blocks on its
## next print — a hang this probe would then report as the suite's own. The copy's stdin is
## the other end of a pipe this process holds open, which is why every suite turns the
## server's stdin console off: a reader blocked on it never lets the copy exit.
func _run_exit_probe() -> Array:
	var seconds := _exit_probe_seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit — %d s allowed)" % seconds)
	var scene := scene_file_path if scene_file_path != "" else "res://examples/dedicated.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	])
	var wrapped := false
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(seconds), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, seconds]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (seconds + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		_drain_exit_probe(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await get_tree().create_timer(0.1).timeout
	# Once more after it exits: what it wrote between the last pass and its exit is still in
	# the pipe, and the leak report is always the last thing it writes.
	_drain_exit_probe(pipes, bytes)

	# OS.kill has already reaped it, and asking for the exit code of a reaped pid is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, seconds]


func _drain_exit_probe(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


func _test_exits_clean(probe: Array) -> void:
	_section("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Every leak line is the engine's, and the engine writes them to stderr; both are
	# searched so that stays a fact about the engine rather than an assumption here. Shown
	# apart, because a pipe each is two streams whose interleaving is lost, and where a hung
	# copy had got to is the end of its stdout.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so neither of the last two was seen, and
	# passing them on an absence of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))
	_finished()


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))
