extends Node

const DrAudio := preload("../game/dr_audio.gd")
const DrCatalogue := preload("../game/dr_catalogue.gd")
const DrConfig := preload("../game/dr_config.gd")
const DrCourse := preload("../game/dr_course.gd")
const DrGame := preload("../game/dr_game.gd")
const DrPlayer := preload("../game/dr_player.gd")

## Every installed course, played: run to its end by a stand-in, every trap sprung on somebody
## standing in it, every button walked to, and the end arena stood in by both sides.
##
## [b]A course is content, and content is checked by playing it.[/b] A document that validates
## can still have a gap nobody clears, a trapdoor whose leaves swing UP, a button an activator
## cannot reach from the walkway, or an arena whose spawn is over the lava — and none of those
## is an error anywhere. Each trap names a `victim` spot for exactly this: somebody stands
## there, survives until the button, and does not survive it.
##
## [b]Ticks are not paced by the engine's frames[/b], because every course at real time is
## minutes. The simulation does not notice: every tick is a fixed step the suite drives, every
## moving body is a static body written straight into the physics server (see [DrCourse]),
## and the rays a stand-in casts read that server directly.

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()
var _world: DrGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("deathrun: every course played")
	print("")

	var catalogue := DrCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	var courses := catalogue.courses.keys()
	courses.sort()

	if courses.size() <= 1:
		print("(no course directory: the built-in practice course only)")

	_section("every document loads")
	_check(catalogue.refused.is_empty(), "none was refused", str(catalogue.refused))
	_check_machinery(catalogue)
	_finished()

	var traps := 0
	var spared := 0

	for id: StringName in courses:
		var doc: Dictionary = catalogue.courses[id]
		traps += (doc["traps"] as Array).size()
		for trap: Dictionary in doc["traps"]:
			spared += 1 if trap.has("spared") else 0
		await _run_course(doc)
		await _spring_every_trap(doc)
		await _walk_to_every_button(doc)
		await _stand_in_the_end(doc)

	if _world != null:
		remove_child(_world)
		_world.free()

	var sections := 1 + courses.size() * 4
	var checks := 2 + courses.size() * (2 + 1 + 2) + traps + spared

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != sections:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, sections
		])
		code = 1

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, checks
		])
		code = 1

	get_tree().quit(code)


## Every trap sounds like what it is, told from its parts: the traps whose machine is not in
## doubt, wherever they are in the catalogue, and a practice-only build checks its own.
func _check_machinery(catalogue: DrCatalogue) -> void:
	var expected := {
		"fd_saws": DrAudio.TRAP_SAW, "fd_jets": DrAudio.TRAP_FIRE, "fd_press": DrAudio.TRAP_CRUSH,
		"fd_steps": DrAudio.TRAP_DROP, "fd_bridge": DrAudio.TRAP_DROP, "ice_trapdoor": DrAudio.TRAP_DROP,
		"ice_walls": DrAudio.TRAP_GRIND, "ice_jaws": DrAudio.TRAP_CRUSH,
	}
	var wrong := PackedStringArray()
	var heard := {}

	for id: StringName in catalogue.courses:
		for trap: Dictionary in catalogue.courses[id]["traps"]:
			var sound := DrAudio.trap_sound(trap)
			heard[sound] = true

			if expected.has(trap["id"]) and expected[trap["id"]] != sound:
				wrong.append("%s is %s" % [trap["id"], sound])

	var named := DrAudio.trap_sound({"sound": "grind", "parts": [{"spin": 900.0}]}) == DrAudio.TRAP_GRIND
	_check(wrong.is_empty() and named and (catalogue.courses.size() <= 1 or heard.size() >= 4),
		"every trap sounds like its machine, and a document can say which", "%s; %d kinds" % [", ".join(wrong), heard.size()])


## A stand-in runs the course with nobody pressing anything, and gets to the end.
func _run_course(doc: Dictionary) -> void:
	_section("%s: a stand-in runs it to the end" % doc["id"])
	var game := await _fresh(doc)
	var bot := game.add_player(&"u900000", "Runner")
	bot.is_bot = true
	var idle := game.add_player(&"u2", "Idle")
	await _begin(game, [bot], [idle])

	var limit := game.round_limit()
	var finished_at := -1.0

	for i in range(int(limit * TICK_RATE)):
		idle.controller.apply_command(DotFpsCommand.new())
		await _tick(game, i)

		if bot.finished:
			finished_at = game.run_elapsed
			break

		if not bot.is_alive():
			break

	_check(bot.finished, "it got there", "alive %s, at %s, heading for route point %d" % [
		bot.is_alive(), bot.controller.state.position, int(game._bot_route.get(bot.player_id, 0))])
	_check(finished_at > 0.0 and finished_at < limit * 0.5, "in under half the round's clock",
		"%.1f s of %.0f" % [finished_at, limit])
	_finished()


## Somebody at each trap's victim spot, alive until it is pressed and not after.
func _spring_every_trap(doc: Dictionary) -> void:
	_section("%s: every trap catches somebody standing in it" % doc["id"])
	var game := await _fresh(doc)
	var victim := game.add_player(&"u1", "Victim")
	var spare := game.add_player(&"u2", "Spare")
	var dodger := game.add_player(&"u4", "Dodger")
	var activator := game.add_player(&"u3", "Activator")
	await _begin(game, [victim, spare, dodger], [activator])
	await _ticks(game, int((game.config.countdown_seconds + 0.2) * TICK_RATE))

	for index in range(game.stage.trap_count()):
		var spec: Dictionary = game.stage.traps[index]["spec"]
		var name := "%s (%s)" % [spec["name"], spec["id"]]

		if not spec.has("victim"):
			_check(false, name, "the trap has no victim spot to test it with")
			continue

		game.stage.reset_traps()
		_revive(game, victim)
		victim.place_at((spec["victim"] as Vector3) + Vector3(0.0, 0.1, 0.0), 0.0)
		# The spare stays at the start, alive, so one death does not end the round.
		spare.place_at(game.stage.start_spot(0, 1)[0], 0.0)
		# A trap with a `spared` spot has somebody there too, who has to come through it; one
		# without parks them at the start beside the spare.
		_revive(game, dodger)
		var dodges := spec.has("spared")
		dodger.place_at(((spec["spared"] as Vector3) + Vector3(0.0, 0.1, 0.0)) if dodges \
			else game.stage.start_spot(0, 1)[0] + Vector3(1.0, 0.0, 0.0), 0.0)
		await _ticks(game, TICK_RATE / 2)
		var stood := victim.is_alive()
		var pressed := game.press(index, activator.player_id)
		await _ticks(game, TICK_RATE * 3)
		_check(stood and pressed and not victim.is_alive(), name,
			"stood %s, pressed %s, then at %s" % [stood, pressed, victim.controller.state.position])
		if dodges:
			_check(dodger.is_alive(), name + ", and misses whoever stands clear of it",
				"spared spot %s, then at %s" % [spec["spared"], dodger.controller.state.position])

	_finished()


## The activator walks from where a round puts them to each button in turn, straight along the
## walkway, and is close enough to press it when they get there.
func _walk_to_every_button(doc: Dictionary) -> void:
	_section("%s: an activator can walk to every button" % doc["id"])
	var game := await _fresh(doc)
	var runner := game.add_player(&"u1", "Runner")
	var activator := game.add_player(&"u2", "Activator")
	await _begin(game, [runner], [activator])

	var missed := PackedStringArray()

	for index in range(game.stage.trap_count()):
		var button := game.stage.button_point(index)
		var reached := false

		for i in range(TICK_RATE * 15):
			var eyes := activator.eye_position()
			var look := button - eyes
			var flat := Vector3(look.x, 0.0, look.z)
			var command := DotFpsCommand.new()
			command.yaw = rad_to_deg(atan2(-look.x, -look.z))
			command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)

			if flat.length() > game.config.button_reach * 0.6:
				command.move = Vector2(0.0, 1.0)
			elif game.stage.button_for(eyes, activator.aim_direction(), game.config.button_reach,
					game.config.button_cone) == index:
				reached = true
				break

			activator.controller.apply_command(command)
			runner.controller.apply_command(DotFpsCommand.new())
			await _tick(game, i)

		if not reached:
			missed.append("%s from %s" % [game.stage.trap_name(index), activator.controller.state.position])

	_check(missed.is_empty(), "every one, walking", ", ".join(missed))
	_finished()


## Both ends of the arena are floor, and nothing there kills anybody standing still.
func _stand_in_the_end(doc: Dictionary) -> void:
	_section("%s: the end arena holds both sides" % doc["id"])
	var game := await _fresh(doc)
	var runner := game.add_player(&"u1", "Runner")
	var activator := game.add_player(&"u2", "Activator")
	await _begin(game, [runner], [activator])
	await _ticks(game, int((game.config.countdown_seconds + 0.2) * TICK_RATE))

	runner.place_at(doc["finish"]["at"], 0.0)
	await _ticks(game, TICK_RATE * 2)
	var runner_spot: Vector3 = game.stage.end_spot(true, 0)[0]
	var activator_spot: Vector3 = game.stage.end_spot(false, 0)[0]
	_check(runner.at_end and runner.is_alive() and absf(runner.controller.state.position.y - runner_spot.y) < 0.5,
		"a runner across the line stands in the arena", str(runner.controller.state.position))
	_check(activator.at_end and activator.is_alive() and absf(activator.controller.state.position.y - activator_spot.y) < 0.5,
		"and so does the activator called down to it", str(activator.controller.state.position))
	_finished()


# --- Helpers ------------------------------------------------------------------------

func _fresh(doc: Dictionary) -> DrGame:
	if _world != null:
		remove_child(_world)
		_world.free()
		await get_tree().process_frame

	var config := DrConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.minimum_players = 0
	config.bot_fumble_chance = 0.0
	config.keep_progress = false
	config.activator_may_repeat = true
	config.course_ids = PackedStringArray([str(doc["id"])])

	_world = DrGame.new()
	_world.name = "World"
	_world.config = config
	_world.tick_rate = TICK_RATE
	_world.register_service = false
	add_child(_world)
	_world.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	return _world


## Starts a round and puts [param runners] and [param activators] on their sides, whoever the
## draw picked.
func _begin(game: DrGame, runners: Array, activators: Array) -> void:
	game.start()
	await _ticks(game, 2)

	for player: DrPlayer in runners:
		game._set_side(player.player_id, DrGame.RUNNERS)

	for player: DrPlayer in activators:
		game._set_side(player.player_id, DrGame.ACTIVATORS)

	game._place_everybody()
	await _ticks(game, 2)


func _revive(game: DrGame, player: DrPlayer) -> void:
	player.reset_progress()
	player.health.health = player.health.max_health
	player.health.alive = true
	player.health.invulnerable = false

	if game.spectate != null:
		game.spectate.on_spawned(player.player_id)


func _ticks(game: DrGame, count: int) -> void:
	for i in range(count):
		await _tick(game, i)


## One tick, and a frame every second of them so the process stays responsive.
func _tick(game: DrGame, i: int) -> void:
	game.simulate(TICK)

	if i % TICK_RATE == TICK_RATE - 1:
		await get_tree().process_frame


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
