extends Node

const DrCatalogue := preload("../game/dr_catalogue.gd")
const DrConfig := preload("../game/dr_config.gd")
const DrGame := preload("../game/dr_game.gd")
const DrPlayer := preload("../game/dr_player.gd")

## Bot soak on the real game: N stand-ins race one course for M simulated minutes through dot-bot's
## DotBotSoak, fed by dot-spawn's DotSpawnWatch. A "map" here is a course id. The game draws the
## sides itself, so with 4 stand-ins it is 3 runners and 1 activator at the buttons.
##
## [codeblock]
## ./game.sh soak [course] [minutes]
## godot --headless --path . res://tools/soak.tscn -- --map dr_temple --bots 4 --minutes 2
## [/codeblock]
##
## --probe 1 prints, once a second, each activator's place, target trap and distance to its button.
## Takes the harness's own flags too (--soak-max-stuck-sec and the rest of DotBotSoakConfig).
## Writes .godot/test-logs/soak-<course>.json, prints the SOAK line, exits 1 when the run fails.
## Rounds run back to back (no warm-up or intermission). A bot is only judged stuck while the
## course is open and it has not finished. Kills are off: a trap's death is the game.

const DEFAULT_MAP := &"dr_temple"
const DEFAULT_MINUTES := 1.0
const DEFAULT_BOTS := 4
const TICK_RATE := 64

var _game: DrGame
var _tick := 0
var _traps := 0
var _finishes := 0
var _reached := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1]
	return fallback


func _run() -> void:
	var map_id := StringName(_arg("map", String(DEFAULT_MAP)))
	var cfg := DotBotSoakConfig.new()
	cfg.minutes = DEFAULT_MINUTES
	cfg.bots = DEFAULT_BOTS
	cfg.apply_cli()
	cfg.minutes = float(_arg("minutes", str(cfg.minutes)))
	cfg.bots = int(_arg("bots", str(cfg.bots)))

	var catalogue := DrCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	if not catalogue.courses.has(map_id):
		_fail("no course %s" % map_id)
		return

	var config := DrConfig.new()
	config.bot_fumble_chance = 0.0
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.minimum_players = 0
	config.keep_progress = false
	config.course_ids = PackedStringArray([String(map_id)])

	_game = DrGame.new()
	_game.name = "World"
	_game.config = config
	_game.tick_rate = TICK_RATE
	_game.register_service = false
	add_child(_game)
	_game.set_physics_process(false)
	_game.trap_fired.connect(func(_i: int, _t: int, _by: StringName) -> void: _traps += 1)
	_game.player_finished.connect(func(_id: StringName, _p: int, _s: float) -> void: _finishes += 1)

	var taken: Array = []
	for i in range(cfg.bots):
		var bot_name := DotBotNames.pick(taken, i, DrGame.BOT_NAMES)
		taken.append(bot_name)
		var bot := _game.add_player(StringName("u%d" % (900100 + i)), bot_name)
		bot.is_bot = true
	await get_tree().physics_frame
	await get_tree().physics_frame
	_game.start()

	var watch := DotSpawnWatch.new()
	watch.rules.enabled = true
	watch.rules.kill_y = -5000.0

	var soak := DotBotSoak.new(cfg)
	soak.watch = watch
	soak.movers_fn = _movers
	soak.object_count_fn = func() -> int: return int(Performance.get_monitor(Performance.OBJECT_COUNT))
	soak.step_fn = _step

	var delta := 1.0 / float(TICK_RATE)
	while not soak.is_done():
		soak.advance(delta)
		# Yield now and then so deferred frees run.
		if soak.ticks % 32 == 0:
			await get_tree().physics_frame

	var report := soak.finish()
	report["map"] = String(map_id)
	report["rounds"] = _game.round_number
	report["traps_fired"] = _traps
	report["finishes"] = _finishes
	report["button_reaches"] = _reached
	# A stand-in that never reaches a button is a dead game. One that reaches them and presses
	# nothing is runners who never stop: they run at the activator's own speed from a start
	# ahead of it, so it arrives as they leave (dr_internet, dr_parking_garage).
	if _game.stage != null and _game.stage.trap_count() > 0 and _traps == 0 and _reached == 0 and cfg.minutes >= 0.5:
		report["ok"] = false
		(report["reasons"] as Array).append("the activator stand-in neither pressed nor reached a button in %d rounds" % _game.round_number)
	print(DotBotSoak.summary(report))
	print(DotBotSoak.report_line(report))
	var path := ProjectSettings.globalize_path("res://.godot/test-logs/soak-%s.json" % map_id)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if soak.write_report(report, path) != OK:
		push_error("could not write %s" % path)
	await _release_game()
	get_tree().quit(0 if report["ok"] else 1)


## Frees the game before quitting: a world still loaded at quit can abort the process.
func _release_game() -> void:
	_game.queue_free()
	for _i in range(3):
		await get_tree().process_frame


func _step(_delta: float) -> void:
	_tick += 1
	_game.simulate(1.0 / float(TICK_RATE))
	if _tick % 8 == 0:
		_count_reaches()
	if _arg("probe", "") != "" and _tick % TICK_RATE == 0:
		_probe()


## Counts the checks (every eighth tick) at which an activator stood within reach of a button.
func _count_reaches() -> void:
	for id: StringName in _game.players:
		if int(_game.sides.get(id, 0)) == DrGame.RUNNERS:
			continue
		var eyes: Vector3 = (_game.players[id] as DrPlayer).eye_position()
		for i in range(_game.stage.trap_count()):
			if eyes.distance_to(_game.stage.button_point(i)) <= _game.config.button_reach:
				_reached += 1
				break


## --probe: once a second, where each activator is, the trap it heads for, and how far from that button.
func _probe() -> void:
	if _tick == TICK_RATE:
		for i in range(_game.stage.trap_count()):
			print("PROBE trap %d button=%s zone=%s" % [i, _game.stage.button_point(i), _game.stage.trap_zone(i)])
		print("PROBE walkway=%s" % [_game.stage.walkway()])
	for id: StringName in _game.players:
		if int(_game.sides.get(id, 0)) == DrGame.RUNNERS:
			print("PROBE runner at=%s fin=%s" % [_game.players[id].controller.state.position, _game.players[id].at_end])
			continue
		var body: DrPlayer = _game.players[id]
		var target: int = _game._bot_target_trap(body)
		var gap := -1.0
		if target >= 0:
			gap = body.eye_position().distance_to(_game.stage.button_point(target))
		print("PROBE t=%d phase=%d at=%s target=%d gap=%.2f walk=%s use=%s fired=%d" % [
			_tick, _game.phase, body.controller.state.position, target, gap,
			_game._bot_walk.get(id, -9), body.wants_use, _traps])


func _movers() -> Array:
	var out: Array = []
	var open: bool = _game.phase == DrGame.Phase.RUN or _game.phase == DrGame.Phase.SHOWDOWN
	for id: StringName in _game.players:
		var body: DrPlayer = _game.players[id]
		out.append({"id": id, "position": body.controller.state.position, "kind": &"bot",
			"has_goal": open and not body.finished and not body.at_end and body.is_alive() \
				and not body.watching and _heading_somewhere(id, body)})
	return out


## A runner always has the course to run. An activator is only judged while it walks to a button:
## once it stands at one (or no runner is left to trap) waiting is its job. A wedged walk still fails.
func _heading_somewhere(id: StringName, body: DrPlayer) -> bool:
	if int(_game.sides.get(id, 0)) == DrGame.RUNNERS:
		return true
	if _game.stage == null:
		return false
	var eyes := body.eye_position()
	for i in range(_game.stage.trap_count()):
		if eyes.distance_to(_game.stage.button_point(i)) <= _game.config.button_reach:
			return false
	return _game._bot_target_trap(body) >= 0


func _fail(why: String) -> void:
	printerr("SOAK setup failed: ", why)
	get_tree().quit(2)
