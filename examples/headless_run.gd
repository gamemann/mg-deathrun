extends Node

const DrBindings := preload("../game/dr_bindings.gd")
const DrCatalogue := preload("../game/dr_catalogue.gd")
const DrConfig := preload("../game/dr_config.gd")
const DrCourse := preload("../game/dr_course.gd")
const DrCourseDoc := preload("../game/dr_course_doc.gd")
const DrClient := preload("../game/dr_client.gd")
const DrEvents := preload("../game/net/dr_events.gd")
const DrNetCommand := preload("../game/net/dr_net_command.gd")
const DrGame := preload("../game/dr_game.gd")
const DrHud := preload("../game/dr_hud.gd")
const DrPaths := preload("../game/dr_paths.gd")
const DrPlayer := preload("../game/dr_player.gd")
const DrProgress := preload("../game/dr_progress.gd")
const DrSettings := preload("../game/dr_settings.gd")

## The simulation, headless: documents, the trap timeline, the draw, the buttons, every shape
## of trap killing somebody, the end, and how a round is decided.
##
## [b]Counts sections AND checks, and the second is the one that matters.[/b] A script error
## inside a section aborts that function and the section counter is already satisfied,
## because the section announced itself on the way in. dot-settings has the story.
##
## Every number about the course here is the built-in practice course's
## ([method DrCatalogue.practice]), whose comment lists where each trap is.

const SECTIONS := 31

const CHECKS := 149

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var _worlds: Array[DrGame] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("deathrun headless run")
	print("")

	_test_config()
	_test_documents()
	_test_the_wire()
	_test_catalogue()
	_test_delivery()
	_test_the_weapon_art_is_vendored()
	_test_the_timeline()
	await _test_world_builds()
	await _test_the_draw()
	await _test_the_gate()
	await _test_the_buttons()
	await _test_the_trapdoor()
	await _test_the_killers()
	await _test_the_carry()
	await _test_a_bot_runs_the_course()
	await _test_the_end()
	await _test_toys()
	await _test_the_traps_win()
	await _test_the_runners_win()
	await _test_the_clock()
	await _test_a_late_joiner()
	await _test_a_bot_at_the_buttons()
	await _test_progress()
	await _test_side_choice()
	await _test_the_client_settings()
	await _test_the_hud()
	await _test_help_and_menu()
	await _test_the_map_menu()
	await _test_offline_trigger()
	await _test_free_roam()
	await _test_the_drawn_gun()

	for world in _worlds.duplicate():
		await _dispose(world)

	await get_tree().process_frame

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != SECTIONS:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, SECTIONS
		])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		code = 1

	get_tree().quit(code)


# --- Without a world ------------------------------------------------------------

func _test_config() -> void:
	_section("the configuration")
	var config := DrConfig.new()
	_check(config.validate().ok, "the defaults validate")
	_check(config.activators_for(1) == 0, "one person is not a round")
	_check(config.activators_for(2) == 1 and config.activators_for(15) == 1,
		"one activator up to fifteen players")
	_check(config.activators_for(16) == 2, "two at sixteen")
	_check(config.activators_for(40) == 5, "and five at forty, which the brief asked for")
	_check(config.activators_for(200) == config.max_activators, "never more than the most",
		"%d" % config.activators_for(200))

	config.timeout_winner = 5
	_check(not config.validate().ok, "a timeout winner that is no side is refused")
	_finished()


func _test_documents() -> void:
	_section("a course is a document, and a bad one is refused with a reason")
	var practice := DrCatalogue.practice()
	_check(str(practice.get("id", "")) == "dr_practice", "the practice course validates")
	_check(practice["start"]["at"] is Vector3, "positions are normalised to vectors")
	_check((practice["traps"] as Array).size() == 5, "it has its five traps")

	var timing: Dictionary = (practice["traps"][0] as Dictionary)["timing"]
	_check(timing.has("delay") and is_zero_approx(float(timing["delay"])),
		"an omitted delay is filled in", str(timing))

	var unknown := practice.duplicate(true)
	(unknown["pieces"] as Array).append({"kind": "trampoline", "at": [0, 0, 0]})
	var refused := DrCourseDoc.validate(unknown)
	_check(not refused.ok and str(refused.error).contains("trampoline"),
		"an unknown piece kind is refused, naming it", str(refused.error) if not refused.ok else "")

	var no_button := practice.duplicate(true)
	(no_button["traps"][0] as Dictionary).erase("button")
	refused = DrCourseDoc.validate(no_button)
	_check(not refused.ok and str(refused.error).contains("button"),
		"a trap with no button is refused, saying so")

	var no_parts := practice.duplicate(true)
	(no_parts["traps"][1] as Dictionary)["parts"] = []
	_check(not DrCourseDoc.validate(no_parts).ok, "a trap that moves nothing is refused")

	var twice := practice.duplicate(true)
	(twice["traps"][1] as Dictionary)["id"] = "trapdoor"
	refused = DrCourseDoc.validate(twice)
	_check(not refused.ok and str(refused.error).contains("trapdoor"), "two traps with one id is refused")

	var ugly := practice.duplicate(true)
	((ugly["traps"][2] as Dictionary)["parts"][0] as Dictionary)["look"] = "glitter"
	_check(not DrCourseDoc.validate(ugly).ok, "a part that looks like nothing this build draws is refused")

	var later := practice.duplicate(true)
	later["format"] = 2
	_check(not DrCourseDoc.validate(later).ok, "a document from a later format is refused")

	var no_end := practice.duplicate(true)
	no_end.erase("end")
	_check(not DrCourseDoc.validate(no_end).ok, "a course with no end arena is refused")

	var lethal: Dictionary = (practice["traps"][1] as Dictionary)["parts"][0]
	_check(bool(lethal["lethal"]) and not bool(lethal["solid"]),
		"a part that kills is not solid unless the document says so")
	_finished()


func _test_the_wire() -> void:
	_section("the document travels, and arrives as the same document")
	var practice := DrCatalogue.practice()
	var bytes := DrCourseDoc.encode(practice)
	var back := DrCourseDoc.decode(bytes)
	_check(back.ok, "it decodes", back.error.message if not back.ok else "")
	_check(back.ok and DrCourseDoc.digest(back.value) == DrCourseDoc.digest(practice),
		"its digest is the one the server sent", "%d bytes" % bytes.size())
	_check(bytes.size() < DrCourseDoc.WIRE_LIMIT, "it is under the wire limit")

	var torn := bytes.slice(0, bytes.size() / 2)
	_check(not DrCourseDoc.decode(torn).ok, "half of it is refused, not built")

	# A death carries how the body falls (dot-player-char's DotPlayerDeath), last and optional.
	var fall := DotPlayerDeath.new()
	fall.reaction = &"face_plant"
	fall.roll_seed = 1234
	fall.damage = 100.0
	fall.direction = Vector3(1, 0, 0)
	var died := DrEvents.read_death(DotNetReader.new(DrEvents.write_death(5, 6, DrGame.DIED_SHOT, fall)))
	var carried: DotPlayerDeath = died.get("death")
	_check(bool(died["ok"]) and carried != null and carried.reaction == &"face_plant" and carried.roll_seed == 1234
		and carried.direction.distance_to(Vector3(1, 0, 0)) < 0.02, "a DEATH carries the fall the server picked")
	var bare := DrEvents.read_death(DotNetReader.new(DrEvents.write_death(5, 6, DrGame.DIED_SHOT)))
	_check(bool(bare["ok"]) and not bare.has("death"), "and one without a fall still reads")
	_finished()


func _test_catalogue() -> void:
	_section("the catalogue")
	var catalogue := DrCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	_check(catalogue.courses.has(DrCatalogue.PRACTICE), "the built-in course is always there")
	_check(catalogue.refused.is_empty(), "no installed document was refused",
		", ".join(catalogue.refused.keys()))

	var ids := catalogue.playable_courses(PackedStringArray())
	_check(ids.size() == 1 or not ids.has(DrCatalogue.PRACTICE),
		"practice drops out once there is a real course", "%d playable" % ids.size())

	var stream := DotRandomStream.new(7)
	var first := catalogue.next_course(PackedStringArray(), true, stream, &"")
	var second := catalogue.next_course(PackedStringArray(), true, stream, StringName(str(first["id"])))
	_check(ids.size() < 2 or str(first["id"]) != str(second["id"]),
		"a shuffle does not repeat the course just played")
	_finished()


## Every bare `"res://…"` string in a shipped script that names one of this game's own
## directories, and every `class_name`. A delivered pack cannot use either; see
## mg-smash-copter's Decision 7.
func _test_delivery() -> void:
	_section("what a delivered pack cannot do, nobody here does")
	var bare := PackedStringArray()
	var named := PackedStringArray()
	var own := ["game", "scenes", "assets", "textures", "courses", "audio"]

	for path in _scripts("res://game"):
		var lines := FileAccess.get_file_as_string(path).split("\n")

		for index in range(lines.size()):
			var line := lines[index].strip_edges()

			if line.begins_with("#"):
				continue

			if line.begins_with("class_name "):
				named.append("%s:%d" % [path, index + 1])

			for folder in own:
				var needle := "\"res://%s/" % folder

				if line.contains(needle) and not line.contains("Paths.rebase(\"res://%s/" % folder):
					bare.append("%s:%d" % [path, index + 1])

	_check(named.is_empty(), "no class_name anywhere", ", ".join(named))
	_check(bare.is_empty(), "no bare res:// path to this game's own files", ", ".join(bare))

	var root := "res://dot_cloud/someone/mg-deathrun/1.0.0/"
	var once := DrPaths.rebase_onto("res://textures/prototype/deck.png", root)
	_check(once == root + "textures/prototype/deck.png", "a path is rebased onto a mount", once)
	_check(DrPaths.rebase_onto(once, root) == once, "and a rebased path is left alone")
	_finished()


func _scripts(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)

	if dir == null:
		return out

	for file in dir.get_files():
		if file.ends_with(".gd"):
			out.append(dir_path.path_join(file))

	for sub in dir.get_directories():
		out.append_array(_scripts(dir_path.path_join(sub)))

	return out


## A trap's timeline, where it is pure: no world, no physics.
func _test_the_timeline() -> void:
	_section("a trap is a function of the tick it was pressed on")
	var timing := {"delay": 0.5, "out": 0.4, "hold": 1.0, "back": 0.6}
	_check(is_zero_approx(DrCourse.extension(timing, -1.0)), "not pressed is home")
	_check(is_zero_approx(DrCourse.extension(timing, 0.3)), "inside its delay it has not moved")
	_check(is_equal_approx(DrCourse.extension(timing, 1.2), 1.0), "held, it is all the way out")
	_check(DrCourse.extension(timing, 2.1) > 0.0 and DrCourse.extension(timing, 2.1) < 1.0,
		"going back, it is part of the way", "%.2f" % DrCourse.extension(timing, 2.1))
	_check(is_zero_approx(DrCourse.extension(timing, 2.6)), "and home after", "%.2f" % DrCourse.extension(timing, 2.6))

	var forever := {"delay": 0.0, "out": 0.3, "hold": -1.0, "back": 1.0}
	_check(is_equal_approx(DrCourse.extension(forever, 600.0), 1.0) and DrCourse.duration(forever) == INF,
		"a negative hold stays out for the round")
	_finished()


# --- A world --------------------------------------------------------------------

func _test_world_builds() -> void:
	_section("a world builds its course, its traps and their buttons")
	var game := await _world()
	_check(game.stage.pieces.size() == (game.course_doc["pieces"] as Array).size(),
		"every piece in the document was built", "%d" % game.stage.pieces.size())
	_check(game.stage.trap_count() == 5, "every trap was built", "%d" % game.stage.trap_count())

	var a := game.add_player(&"u1", "Ada")
	var b := game.add_player(&"u2", "Bo")
	await _step(game, 4)
	var start: Vector3 = game.course_doc["start"]["at"]
	_check(absf(a.controller.state.position.y - start.y) < 0.6 and a.controller.state.position.distance_to(start) < 5.0,
		"a joiner stands in the start", str(a.controller.state.position))
	_check(a.controller.state.position.distance_to(b.controller.state.position) > 1.0,
		"two joiners are not put inside each other")
	_finished()


func _test_the_draw() -> void:
	_section("the activators are drawn each round, and not the same one twice running")
	var game := await _world()
	var ids: Array[StringName] = []

	for i in range(4):
		ids.append(game.add_player(StringName("u%d" % (i + 1)), "P%d" % i).player_id)

	game.start()
	await _step(game, 2)
	var first := game.players_on(DrGame.ACTIVATORS)
	_check(first.size() == 1, "four players, one activator", "%d" % first.size())
	_check(game.players_on(DrGame.RUNNERS).size() == 3, "and three runners")

	var corridor: Dictionary = game.course_doc["activators"]
	_check(not first.is_empty() and first[0].controller.state.position.distance_to(corridor["at"]) < 4.0,
		"the activator starts in their corridor",
		str(first[0].controller.state.position) if not first.is_empty() else "")

	var repeated := 0
	var last: StringName = first[0].player_id if not first.is_empty() else &""

	for round_index in range(4):
		game._decide(DrGame.ACTIVATORS, "test")
		await _step(game, 3)
		await _step(game, 2)
		var now := game.players_on(DrGame.ACTIVATORS)

		if not now.is_empty() and now[0].player_id == last:
			repeated += 1

		last = now[0].player_id if not now.is_empty() else &""

	_check(repeated == 0, "four more rounds, and nobody was drawn twice running", "%d repeats" % repeated)
	_finished()


func _test_the_gate() -> void:
	_section("the start gate holds through the countdown, and drops")
	var game := await _world(func(c: DrConfig) -> void: c.countdown_seconds = 1.5)
	var players := await _round(game, 2)
	var runner := players[0]
	_check(game.phase == DrGame.Phase.COUNTDOWN and game.stage.gate_closed, "the round starts behind the gate")

	var start: Vector3 = game.course_doc["start"]["at"]
	await _hold_for(game, runner, Vector2(0, 1), 0.0, int(1.2 * TICK_RATE))
	_check(runner.controller.state.position.z > start.z - 3.4,
		"running at it during the countdown goes nowhere past it", "z %.2f" % runner.controller.state.position.z)

	await _hold_for(game, runner, Vector2(0, 1), 0.0, int(1.0 * TICK_RATE))
	_check(game.phase == DrGame.Phase.RUN and not game.stage.gate_closed, "then it drops")
	_check(runner.controller.state.position.z < start.z - 4.0, "and the runner is through",
		"z %.2f" % runner.controller.state.position.z)
	_finished()


func _test_the_buttons() -> void:
	_section("a button fires its trap once, for an activator, when the gate is down")
	var game := await _world(func(c: DrConfig) -> void: c.countdown_seconds = 1.0)
	var players := await _round(game, 2)
	var activator := players[1]
	var fired: Array = []
	var refused: Array = []
	game.trap_fired.connect(func(i: int, t: int, by: StringName) -> void: fired.append([i, t, by]))
	game.button_refused.connect(func(id: StringName, why: String) -> void: refused.append(why))

	await _press(game, activator, 0)
	_check(fired.is_empty() and not refused.is_empty(), "behind the gate, a press is refused",
		str(refused))

	await _step(game, int(1.1 * TICK_RATE))
	await _press(game, activator, 0)
	_check(fired.size() == 1 and int(fired[0][0]) == 0 and StringName(fired[0][2]) == activator.player_id,
		"once it is down, the trap fires, credited to whoever pressed", str(fired))

	refused.clear()
	await _press(game, activator, 0)
	_check(fired.size() == 1 and not refused.is_empty(), "pressed again, it is spent", str(refused))

	# Too far from the button: four metres along the walkway from it, looking straight at it.
	var button := game.stage.button_point(1)
	activator.place_at(button + Vector3(1.0, -DrCourse.BUTTON_HEIGHT + 0.05, 4.0), 0.0)
	await _step(game, 2)
	await _use(game, activator, button)
	_check(fired.size() == 1, "out of reach, nothing happens")

	# A runner standing at the button presses nothing: the buttons are the activators'.
	var runner := players[0]
	runner.place_at(button + Vector3(1.0, -DrCourse.BUTTON_HEIGHT + 0.05, 0.0), 90.0)
	await _step(game, 2)
	await _use(game, runner, button)
	_check(fired.size() == 1, "a runner at a button presses nothing")
	_finished()


func _test_the_trapdoor() -> void:
	_section("a trapdoor drops whoever is on it into the spikes, and the activator is credited")
	var game := await _world(func(c: DrConfig) -> void: c.countdown_seconds = 0.2)
	var players := await _round(game, 3)
	var victim := players[0]
	var bystander := players[1]
	var activator := players[2]
	var deaths := _deaths(game)
	await _step(game, int(0.3 * TICK_RATE))

	victim.place_at(Vector3(1.4, 0.1, -13.0), 0.0)
	bystander.place_at(Vector3(0.0, 0.1, -6.0), 0.0)
	await _step(game, int(0.5 * TICK_RATE))
	_check(victim.is_alive() and absf(victim.controller.state.position.y) < 0.3,
		"before the press it is a floor", str(victim.controller.state.position))

	# Drawn while alive, as a client draws everybody it can see: the body is copied from this.
	var _drawn := victim.present_body(false, victim.controller.state.position, Color.WHITE)
	await _press(game, activator, 0)
	await _step(game, TICK_RATE * 2)
	_check(not victim.is_alive(), "after it, the one on it is gone", str(victim.controller.state.position))
	_check(bystander.is_alive(), "and the one beside it is not")
	_check(_died(deaths, victim.player_id, activator.player_id), "it is the activator's kill", str(deaths))

	# How the body falls: the server picked it, and a client draws it from the figure.
	_check(victim.death != null and DotPlayerDeathReactions.stock().has(victim.death.reaction),
		"the server picked how the body falls", str(victim.death.describe()) if victim.death != null else "none")
	var client := DrClient.new()
	client.game = game
	client._build_ragdolls()
	client.remove_child(client.ragdolls)
	add_child(client.ragdolls)
	client._fall(victim)
	_check(client.ragdolls.live().size() == 1 and client.ragdolls.rules == game.ragdoll_rules,
		"and a client builds the body from the figure it draws, under the game's rules")
	client.ragdolls.queue_free()
	client.free()
	_finished()


func _test_the_killers() -> void:
	_section("a spike wall, a crusher and fire each kill whoever is in them, and nobody else")
	var game := await _world(func(c: DrConfig) -> void: c.countdown_seconds = 0.2)
	var players := await _round(game, 5)
	var walled := players[0]
	var crushed := players[1]
	var burned := players[2]
	var spared := players[3]
	var activator := players[4]
	var deaths := _deaths(game)
	await _step(game, int(0.3 * TICK_RATE))

	walled.place_at(Vector3(-1.5, 0.1, -21.0), 0.0)
	crushed.place_at(Vector3(0.5, 0.1, -27.0), 0.0)
	burned.place_at(Vector3(0.0, 0.1, -46.0), 0.0)
	spared.place_at(Vector3(0.0, 0.1, -24.0), 0.0)

	# Crouching under the fire does not help: it fills the corridor to head height.
	var duck := DotFpsCommand.new()
	duck.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	burned.controller.apply_command(duck)
	await _step(game, 4)

	for index in [1, 2, 4]:
		await _press(game, activator, index)

	await _step(game, TICK_RATE * 2)
	_check(not walled.is_alive() and _why(deaths, walled.player_id) == DrGame.DIED_TRAP,
		"the spike wall crossed the corridor through them", str(walled.controller.state.position))
	_check(not crushed.is_alive(), "the crusher came down on them")
	_check(not burned.is_alive(), "the fire caught them, crouched")
	_check(spared.is_alive(), "and the runner standing between two traps is fine")
	_finished()


func _test_the_carry() -> void:
	_section("a falling block carries whoever is on it down with it")
	var game := await _world(func(c: DrConfig) -> void: c.countdown_seconds = 0.2)
	var players := await _round(game, 2)
	var rider := players[0]
	var activator := players[1]
	var deaths := _deaths(game)
	await _step(game, int(0.3 * TICK_RATE))

	rider.place_at(Vector3(1.0, 0.1, -35.5), 0.0)
	await _step(game, TICK_RATE)
	var before := rider.controller.state.position
	_check(rider.is_alive() and absf(before.y) < 0.3, "standing on a block, they stay up",
		str(before))

	# Not "are they still alive": the one runner caught ends the round, and the next round has
	# already stood them back up at the start.
	await _press(game, activator, 3)
	# The tell first: a trap waits trap_tell_seconds after its button before it moves.
	_check(game.stage.is_telling(3, float(game.current_tick()) / float(TICK_RATE)) and rider.controller.state.position.y > before.y - 0.1,
		"pressed, the trap tells first, and nobody moves")
	await _step(game, int((0.15 + game.config.trap_tell_seconds) * TICK_RATE))
	_check(rider.controller.state.position.y < before.y - 0.8, "then they go down with it",
		str(rider.controller.state.position))
	await _step(game, TICK_RATE)
	_check(_died(deaths, rider.player_id, activator.player_id), "into the pit, the activator's kill",
		str(deaths))
	_finished()


func _test_a_bot_runs_the_course() -> void:
	_section("a stand-in runs the practice course to its end when nobody presses anything")
	var game := await _world(func(c: DrConfig) -> void:
		c.bot_fumble_chance = 0.0
		c.countdown_seconds = 0.5
	)
	var bot := game.add_player(&"u900000", "Bot")
	bot.is_bot = true
	var other := game.add_player(&"u2", "Bo")
	game.config.activator_may_repeat = true
	game.start()
	await _step(game, 2)

	# Whoever was drawn, the bot runs: the other is put at the buttons.
	game._set_side(bot.player_id, DrGame.RUNNERS)
	game._set_side(other.player_id, DrGame.ACTIVATORS)
	game._place_everybody()
	var finished_at := -1.0
	var top_speed := 0.0

	for i in range(TICK_RATE * 40):
		other.controller.apply_command(DotFpsCommand.new())
		await _step(game, 1)
		var v := bot.controller.state.velocity
		top_speed = maxf(top_speed, Vector2(v.x, v.z).length())

		if bot.finished:
			finished_at = game.run_elapsed
			break

	_check(bot.finished and bot.place == 1, "it got to the end", "at %s, alive %s" % [
		bot.controller.state.position, bot.is_alive()])
	_check(finished_at > 0.0 and finished_at < 30.0, "inside thirty seconds", "%.1f s" % finished_at)
	_check(top_speed >= game.config.run_speed * 0.95, "its ground speed reaches the run speed (not a walk)",
		"%.2f of %.2f m/s" % [top_speed, game.config.run_speed])
	_finished()


func _test_the_end() -> void:
	_section("the first runner across is armed at the end, and calls the activators to it")
	var game := await _world(func(c: DrConfig) -> void:
		c.countdown_seconds = 0.2
		c.arrival_grace_seconds = 0.5
	)
	var players := await _round(game, 3)
	var runner := players[0]
	var activator := players[2]
	await _step(game, int(0.3 * TICK_RATE))

	runner.place_at(game.course_doc["finish"]["at"], 0.0)
	await _step(game, 2)
	_check(runner.finished and runner.at_end, "across the line, a runner is in the end arena")
	_check(runner.weapons != null, "with a weapon in their hands")
	_check(game.phase == DrGame.Phase.SHOWDOWN and activator.at_end and activator.weapons != null,
		"and the activator has been called down, armed")
	_check(is_equal_approx(activator.health.health, game.config.player_health * game.config.activator_health_scale),
		"tougher, because it is one against several", "%.0f" % activator.health.health)
	_check(runner.health.invulnerable, "nobody can be hurt the moment they arrive")
	await _step(game, int(0.6 * TICK_RATE))
	_check(not runner.health.invulnerable and not activator.health.invulnerable, "and then they can")

	# The end's activator corridor is empty: a press from down here does nothing.
	var fired: Array = []
	game.trap_fired.connect(func(i: int, _t: int, _by: StringName) -> void: fired.append(i))
	activator.wants_use = true
	await _step(game, 2)
	activator.wants_use = false
	_check(fired.is_empty(), "an activator at the end presses nothing")

	# A stand-in's fight is dot-bot's aim: no shot on the tick it first looks, and a preset that
	# reacts faster fires sooner (bot_reaction).
	var first_shot := {}
	for preset in ["easy", "nightmare"]:
		var _p := DotBotSettings.of(game).set_difficulty(preset)
		game._bot_hands.erase(activator.player_id)
		var tick_of := -1
		for t in range(int(2.0 * TICK_RATE)):
			var cmd := DotFpsCommand.new()
			cmd.yaw = activator.controller.state.yaw
			game._tick += 1
			game._aim_bot(activator, cmd, runner)
			if cmd.is_pressed(DotFpsCommand.BUTTON_USER_0):
				tick_of = t
				break
		first_shot[preset] = tick_of
	var _back := DotBotSettings.of(game).set_difficulty("medium")
	_check(int(first_shot["easy"]) > 0 and int(first_shot["nightmare"]) > 0,
		"a stand-in does not fire on the tick it first aims", str(first_shot))
	_check(int(first_shot["nightmare"]) < int(first_shot["easy"]),
		"and a nightmare one fires sooner than an easy one", str(first_shot))
	_finished()


## dot-props' toys on the practice course: a runner walking into the start's football sends it
## on; an armed runner's shot sends the arena's beach ball off and the combat's trace sees
## straight through it, so it is no cover.
func _test_toys() -> void:
	_section("the course's toys")
	var game := await _world()
	# After the round starts: a start builds the course again, and its toys with it.
	var players := await _round(game, 2)
	var box := game.stage.toys
	_check(box != null and box.count() == 3 and box.missing.is_empty(), "the practice course has its three toys", str(box.describe()) if box != null else "none")
	var runner := players[0]
	var ball := box.toy(0)
	var b0 := ball.body.global_position
	runner.place_at(b0 + Vector3(-0.4, -0.12, 0.0), 0.0)
	for _i in range(10):
		runner.controller.state.velocity = Vector3(5.0, 0.0, 0.0)
		game._advance_toys(TICK)
		await get_tree().physics_frame
	for _i in range(20):
		await get_tree().physics_frame
	_check(ball.body.global_position.x > b0.x + 0.3, "a runner walking into the football sends it on", "%.2f m" % (ball.body.global_position.x - b0.x))

	var beach := box.toy(1)
	var o0 := beach.body.global_position
	var shot := DotShot.make(&"test", runner.entity_id, game.current_tick(), 0)
	shot.origin = o0 + Vector3(0.0, 0.0, 5.0)
	shot.direction = Vector3(0.0, 0.0, -1.0)
	shot.damage = 25.0
	shot.max_range = 40.0
	var through := game.combat.trace.line_of_sight(shot.origin, o0 + Vector3(0.0, 0.0, -2.0))
	game._shoot_toys(shot)
	for _i in range(20):
		await get_tree().physics_frame
	_check(beach.body.global_position.distance_to(o0) > 0.4 and through,
		"a shot sends the arena's beach ball off, and the combat's trace sees through it: no cover",
		"%.2f m, clear %s" % [beach.body.global_position.distance_to(o0), str(through)])
	_finished()


func _test_the_traps_win() -> void:
	_section("every runner caught is the activators' round")
	var game := await _world(func(c: DrConfig) -> void: c.countdown_seconds = 0.2)
	var players := await _round(game, 3)
	var ended := _ends(game)
	await _step(game, int(0.3 * TICK_RATE))

	for runner in [players[0], players[1]]:
		(runner as DrPlayer).place_at(Vector3(0.0, -7.0, -35.0), 0.0)

	await _step(game, TICK_RATE)
	_check(ended.size() == 1 and int(ended[0][1]) == DrGame.ACTIVATORS, "the activators won",
		str(ended))
	_finished()


func _test_the_runners_win() -> void:
	_section("an activator put down at the end is the runners' round, and so is one who leaves")
	var game := await _world(func(c: DrConfig) -> void:
		c.countdown_seconds = 0.2
		c.arrival_grace_seconds = 0.1
	)
	var players := await _round(game, 3)
	var runner := players[0]
	var activator := players[2]
	var ended := _ends(game)
	var deaths := _deaths(game)
	await _step(game, int(0.3 * TICK_RATE))

	runner.place_at(game.course_doc["finish"]["at"], 0.0)
	await _step(game, int(0.3 * TICK_RATE))
	var shot := DotDamage.make(runner.entity_id, activator.entity_id, 1000.0, null)
	shot.tick = game.current_tick()
	var _applied := game.combat.apply_damage(shot)
	await _step(game, 3)
	_check(ended.size() == 1 and int(ended[0][1]) == DrGame.RUNNERS, "the runners won", str(ended))
	_check(_died(deaths, activator.player_id, runner.player_id), "the kill is the runner's")
	_check(runner.points == game.config.winner_points + game.config.first_across_points and activator.points == 0,
		"the runner has the win's points and first across; the activator none (%d, %d)" % [runner.points, activator.points])

	var second := await _world(func(c: DrConfig) -> void: c.countdown_seconds = 0.2)
	var others := await _round(second, 3)
	var ended_again := _ends(second)
	await _step(second, int(0.3 * TICK_RATE))
	second.remove_player(others[2].player_id)
	await _step(second, 3)
	_check(ended_again.size() == 1 and int(ended_again[0][1]) == DrGame.RUNNERS,
		"an activator who leaves hands the runners the round", str(ended_again))
	_finished()


func _test_the_clock() -> void:
	_section("the clock is the activators' round by default, and the server's to change")
	var game := await _world(func(c: DrConfig) -> void:
		c.countdown_seconds = 0.2
		c.round_seconds = 30.0
	)
	var _players := await _round(game, 2)
	var ended := _ends(game)
	await _step(game, int(0.3 * TICK_RATE))
	game.run_elapsed = 29.95
	await _step(game, int(0.4 * TICK_RATE))
	_check(ended.size() == 1 and int(ended[0][1]) == DrGame.ACTIVATORS, "the activators won on time",
		str(ended))

	var draw := await _world(func(c: DrConfig) -> void:
		c.countdown_seconds = 0.2
		c.round_seconds = 30.0
		c.timeout_winner = 0
	)
	var _more := await _round(draw, 2)
	var drawn := _ends(draw)
	await _step(draw, int(0.3 * TICK_RATE))
	draw.run_elapsed = 29.95
	await _step(draw, int(0.4 * TICK_RATE))
	_check(drawn.size() == 1 and int(drawn[0][1]) == 0, "with `timeout_winner 0` it is a draw", str(drawn))
	_finished()


func _test_side_choice() -> void:
	_section("a player's choice of side counts in the draw")
	var game := await _world()
	for i in range(6):
		var _p := game.add_player(StringName("c%d" % i), "Chooser %d" % i)
	# Six players is one activator. Everybody but c3 asks to run; c3 volunteers.
	for i in range(6):
		game.wish_side(StringName("c%d" % i), DrGame.RUNNERS)
	game.wish_side(&"c3", DrGame.ACTIVATORS)
	game._last_activators.clear()
	game._draw_sides()
	_check(game.team_of(&"c3") == DrGame.ACTIVATORS, "a volunteer is drawn first")

	# Nobody volunteers and two would rather run: one of the other four is drawn.
	for i in range(6):
		game.wish_side(StringName("c%d" % i), 0)
	game.wish_side(&"c0", DrGame.RUNNERS)
	game.wish_side(&"c1", DrGame.RUNNERS)
	var drawn_reluctant := 0
	for round_number in range(8):
		game._last_activators.clear()
		game._draw_sides()
		if game.team_of(&"c0") == DrGame.ACTIVATORS or game.team_of(&"c1") == DrGame.ACTIVATORS:
			drawn_reluctant += 1
	_check(drawn_reluctant == 0, "somebody who asked to run is not drawn while others can be")

	# Everybody would rather run: there is still an activator.
	for i in range(6):
		game.wish_side(StringName("c%d" % i), DrGame.RUNNERS)
	game._last_activators.clear()
	game._draw_sides()
	var activators := 0
	for i in range(6):
		if game.team_of(StringName("c%d" % i)) == DrGame.ACTIVATORS:
			activators += 1
	_check(activators == 1, "and when everybody would rather run, one still activates")
	_finished()


func _test_a_late_joiner() -> void:
	_section("somebody who joins mid-round watches it, and decides nothing")
	var game := await _world(func(c: DrConfig) -> void: c.countdown_seconds = 0.2)
	var players := await _round(game, 2)
	var ended := _ends(game)
	await _step(game, int(0.5 * TICK_RATE))

	var late := game.add_player(&"u77", "Late")
	await _step(game, 3)
	_check(late.watching and game.alive_on(DrGame.RUNNERS) == 1,
		"they watch, and are not counted as a runner", "%d runners" % game.alive_on(DrGame.RUNNERS))

	players[0].place_at(Vector3(0.0, -7.0, -35.0), 0.0)
	await _step(game, TICK_RATE)
	_check(ended.size() == 1 and int(ended[0][1]) == DrGame.ACTIVATORS,
		"the last real runner caught still ends the round", str(ended))
	_finished()


func _test_a_bot_at_the_buttons() -> void:
	_section("a stand-in at the buttons walks to a trap and presses it on a runner in it")
	var game := await _world(func(c: DrConfig) -> void:
		c.countdown_seconds = 0.2
		c.bot_trap_delay = 0.2
	)
	var runner := game.add_player(&"u1", "Ada")
	var bot := game.add_player(&"u900001", "Bot")
	bot.is_bot = true
	game.start()
	await _step(game, 2)
	game._set_side(runner.player_id, DrGame.RUNNERS)
	game._set_side(bot.player_id, DrGame.ACTIVATORS)
	game._place_everybody()
	var fired: Array = []
	game.trap_fired.connect(func(i: int, _t: int, by: StringName) -> void: fired.append([i, by]))
	var deaths := _deaths(game)
	await _step(game, int(0.3 * TICK_RATE))

	# Standing in the crusher, and waiting for it.
	runner.place_at(Vector3(0.0, 0.1, -27.0), 0.0)

	for _i in range(TICK_RATE * 12):
		runner.controller.apply_command(DotFpsCommand.new())
		await _step(game, 1)

		if not fired.is_empty():
			break

	await _step(game, TICK_RATE)
	_check(not fired.is_empty() and int(fired[0][0]) == 2 and StringName(fired[0][1]) == bot.player_id,
		"it pressed the crusher", str(fired))
	_check(_died(deaths, runner.player_id, bot.player_id), "and the runner in it is gone, the bot's kill",
		str(deaths))
	_finished()


func _test_progress() -> void:
	_section("what a player keeps: a trap's kill is the activator's, and every achievement counts")
	var game := await _world(func(c: DrConfig) -> void: c.countdown_seconds = 0.2)
	var players := await _round(game, 2)
	var victim := players[0]
	var activator := players[1]
	await _step(game, int(0.3 * TICK_RATE))
	victim.place_at(Vector3(0.0, 0.1, -46.0), 0.0)
	await _step(game, 2)
	await _press(game, activator, 4)
	await _step(game, TICK_RATE)

	var values := game.progress.session_values(activator.player_id)
	_check(is_equal_approx(values.get_value(DrProgress.TRAP_KILLS), 1.0),
		"the activator has one runner trapped", str(values.get_value(DrProgress.TRAP_KILLS)))
	_check(is_equal_approx(values.get_value(DrProgress.PRESSES), 1.0), "and one trap sprung")

	var declared := DrProgress.ids()
	var unread := PackedStringArray()

	for achievement in DrProgress.catalogue().achievements:
		for rule in achievement.requirements:
			if not declared.has(rule.stat):
				unread.append(String(rule.stat))

	_check(unread.is_empty(), "every achievement reads a number the schema declares", ", ".join(unread))
	_finished()


# --- Helpers ------------------------------------------------------------------------

## A round on [param game] with [param count] people in it, the LAST of them the one
## activator — whoever the draw picked. Returned runners first.
func _round(game: DrGame, count: int) -> Array[DrPlayer]:
	var out: Array[DrPlayer] = []

	for i in range(count):
		out.append(game.add_player(StringName("u%d" % (i + 1)), "P%d" % (i + 1)))

	game.start()
	await _step(game, 2)

	for i in range(count):
		game._set_side(out[i].player_id, DrGame.ACTIVATORS if i == count - 1 else DrGame.RUNNERS)

	game._place_everybody()
	await _step(game, 2)
	return out


## Puts [param activator] at trap [param index]'s button, looking at it, and presses.
func _press(game: DrGame, activator: DrPlayer, index: int) -> void:
	var button := game.stage.button_point(index)
	# On the walkway beside the button: its top is BUTTON_HEIGHT above the floor it stands on.
	activator.place_at(button + Vector3(1.0, -DrCourse.BUTTON_HEIGHT + 0.05, 0.0), 90.0)
	await _step(game, 1)
	await _use(game, activator, button)


## Looks at [param at] and presses the use key for a tick, then lets go.
func _use(game: DrGame, player: DrPlayer, at: Vector3) -> void:
	var look := at - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	player.controller.apply_command(command)
	await _step(game, 1)
	player.wants_use = true
	await _step(game, 1)
	player.wants_use = false
	await _step(game, 1)


func _deaths(game: DrGame) -> Array:
	var out: Array = []
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void:
		out.append([id, by, why]))
	return out


func _ends(game: DrGame) -> Array:
	var out: Array = []
	game.round_over.connect(func(n: int, w: int, why: String) -> void: out.append([n, w, why]))
	return out


func _died(deaths: Array, id: StringName, by: StringName) -> bool:
	for entry: Array in deaths:
		if StringName(entry[0]) == id and StringName(entry[1]) == by:
			return true

	return false


func _why(deaths: Array, id: StringName) -> StringName:
	for entry: Array in deaths:
		if StringName(entry[0]) == id:
			return StringName(entry[2])

	return &""


## Holds a direction for [param ticks]. Applied every tick, because the motor repeats a
## starved tick's view and buttons but drops its movement.
func _hold_for(game: DrGame, player: DrPlayer, move: Vector2, yaw: float, ticks: int) -> void:
	for _i in range(ticks):
		var command := DotFpsCommand.new()
		command.move = move
		command.yaw = yaw
		player.controller.apply_command(command)
		await _step(game, 1)


## A real offline client, booted: its settings are built and read by its sampler and its
## camera, and Escape opens the screen. Escape used to let go of the mouse and offer nothing.
func _test_the_client_settings() -> void:
	_section("the client's settings are read, and Escape opens them")
	var client: Node = (load("res://game/dr_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)
	# The course used to be drawn, and steered, while it was still being built.
	var platform: DotGameClient = client.get("platform")
	var covered := platform != null and platform.gate != null and not platform.is_shown() \
		and platform.is_input_blocked()
	for i in 240:
		await get_tree().process_frame
		if platform != null and platform.is_shown():
			break
	for i in 2:
		await get_tree().process_frame
	_check(covered and platform.is_shown() and not platform.is_input_blocked() and platform.console != null,
		"the loading cover is up at the start and lifts once the player is in, with the console built",
		str(platform.describe()) if platform != null else "no platform")

	var settings: Variant = client.get("settings")
	var camera: Camera3D = client.get("camera")
	_check(
		settings != null and int(settings.describe().get("look_bound", 0)) > 0 \
			and camera != null and bool(settings.describe().get("camera_bound", false)) \
			and is_equal_approx(camera.fov, float(settings.settings.get_int(&"field_of_view", 0))),
		"the client's settings are read by its sampler and its camera",
		str(settings.describe()) if settings != null else "no settings"
	)
	var escape := InputEventAction.new()
	escape.action = &"ui_cancel"
	escape.pressed = true
	client.call("_unhandled_input", escape)
	_check(settings != null and settings.is_open(), "and Escape opens them")
	settings.close()

	# The Tab board, held: the menu's, drawn from the local world offline.
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	settings.menu.handle_event(tab)
	var board: DotMenuScoreboard = client.get("board")
	_check(board != null and board.is_open() and board.rows().size() >= 1
		and board.rows().any(func(r: Dictionary) -> bool: return bool(r.get("you", false))),
		"Tab holds the scoreboard up, with this player on it and picked out",
		str(board.rows()) if board != null else "no board")
	tab.pressed = false
	settings.menu.handle_event(tab)
	_check(board != null and not board.is_open() and not settings.is_open(), "and letting go puts it away")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


## The HUD's clock, health and trap prompt are dot-ui's glance pieces, handed this world's
## numbers. A headless viewport is 64 x 64, so the layout is checked as arithmetic on two
## bottom-anchored things and looked at with `tools/shot.sh --view=end` and `--view=button`.
func _test_the_hud() -> void:
	_section("the HUD draws the clock, health and the trap prompt through dot-ui")
	var game := await _world(func(c: DrConfig) -> void: c.countdown_seconds = 0.2)
	var players := await _round(game, 2)
	var runner := players[0]
	var activator := players[1]
	await _step(game, int(0.3 * TICK_RATE))

	var hud := DrHud.new()
	add_child(hud)
	hud.use_key = DrClient.USE_KEY
	hud.bind(game, activator)
	hud._process(0.0)
	_check(
		game.phase == DrGame.Phase.RUN and hud.strip.clock == DotScoreStrip.clock_text(game.seconds_left())
		and hud.strip.under_text() == hud._phase_line() and hud._phase_line().contains(" E "),
		"the strip shows the clock, the phase line under it, naming the use key",
		"%s / %s" % [hud.strip.clock, hud.strip.under_text()]
	)

	# At the first button, looking at it: the prompt is the trap's name with the key as a key.
	var button := game.stage.button_point(0)
	activator.place_at(button + Vector3(1.0, -DrCourse.BUTTON_HEIGHT + 0.05, 0.0), 90.0)
	await _step(game, 1)
	var look := button - activator.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	activator.controller.apply_command(command)
	await _step(game, 1)
	hud._process(0.0)
	_check(
		hud.prompt.visible and hud.prompt.words == game.stage.trap_name(0) and hud.prompt.key == "E",
		"looking at a ready button, DotKeyPrompt names its trap with the use key",
		hud.prompt.text()
	)
	var _pressed := game.press(0, activator.player_id)
	await _step(game, 1)
	hud._process(0.0)
	_check(
		hud.prompt.visible and hud.prompt.words.ends_with("spent") and hud.prompt.key == "",
		"spent, it says so and offers no key", hud.prompt.text()
	)

	# Health only at the end.
	hud.bind(game, runner)
	hud._process(0.0)
	_check(not hud.vitals.visible, "a runner on the course has no health on screen")
	runner.at_end = true
	runner.health.health = 17.4
	hud._process(0.0)
	_check(
		hud.vitals.visible and hud.vitals.number_text() == "18" and hud.vitals.is_low(),
		"at the end DotVitals shows it, red at a quarter",
		"%s low=%s" % [hud.vitals.number_text(), str(hud.vitals.is_low())]
	)

	var chat := DrClient.new_chat()
	add_child(chat)
	var w: DotChatWindow = chat.window
	var log_top := w.margin_bottom + w.entry_height + float(w.max_lines) * (w.line_height + w.line_gap)
	var plate_bottom := -(hud.vitals.offset_top + hud.vitals.footprint().end.y)
	_check(
		plate_bottom >= log_top,
		"a full chat log stays under the health plate",
		"log reaches %.0f px off the bottom, the plate ends %.0f off it" % [log_top, plate_bottom]
	)
	chat.queue_free()

	# Christian's first play test: a darker HUD by default, restyled live by the menu's theme.
	var settings := DrSettings.new()
	add_child(settings)
	var _built: Variant = settings.setup(DotSettingsStoreMemory.new())
	hud.follow_menu(settings.menu)
	var plate := hud.vitals.colour(&"plate")
	_check(plate.get_luminance() < 0.1 and plate.a >= 0.7, "the HUD is dark by default, in the menu's theme", str(plate))
	var _t := settings.settings.set_value(&"ui_theme", &"contrast")
	var contrast: DotMenuPalette = settings.menu.palette()
	_check(contrast.id == &"contrast" and hud.vitals.colour(&"plate") == contrast.hud_plate and hud.vitals.colour(&"text") == contrast.hud_text,
		"a theme picked in the menu reaches the pieces at once")
	_check(hud.vitals.colour(&"highlight") == DrHud.COURSE_COLOUR and hud._field.get_theme_color(&"font_color") == contrast.hud_text,
		"keeping this game's accent, and the HUD's own lines follow it too")
	_t = settings.settings.set_value(&"ui_theme", &"midnight")
	settings.queue_free()

	# A pack naming these classes does not parse on a shell whose dot-ui predates them, so
	# the requires.json dot-ci derives must ask for dot-ui 4, and nothing may lower it.
	var asks := DotAddonApi.derive()
	_check(
		int(asks.get("dot_ui", 0)) >= 4 and not FileAccess.file_exists("res://" + DotAddonApi.FLOOR_FILE),
		"the pack asks a shell for dot-ui level 4, the glance pieces",
		str(asks.get("dot_ui"))
	)
	hud.queue_free()
	_finished()


## The family's rule since the first play test: H opens help in every game, nothing else in
## the table is on H, and the Escape menu has Help & commands and Leave.
func _test_help_and_menu() -> void:
	_section("H opens help, and the Escape menu has Help and Leave")
	var settings := DrSettings.new()
	add_child(settings)
	var built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(built.ok and keys != null and keys.key_for(DotMenuBindings.HELP_ACTION) == "H", "help is on H")
	_check(keys.defaults_on("H").size() == 1, "and nothing else in the table defaults to H",
		str(keys.defaults_on("H").map(func(r: Dictionary) -> String: return str(r["label"]))))
	# The wheel cycles weapons and does not jump.
	var wu := InputEventMouseButton.new()
	wu.button_index = MOUSE_BUTTON_WHEEL_UP
	wu.pressed = true
	var wd := InputEventMouseButton.new()
	wd.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wd.pressed = true
	_check(wu.is_action_pressed(DotMenuBindings.WEAPON_PREVIOUS_ACTION) and wd.is_action_pressed(DotMenuBindings.WEAPON_NEXT_ACTION),
		"wheel up is previous weapon and wheel down is next")
	_check(not wu.is_action_pressed(&"dot_fps_jump") and not wd.is_action_pressed(&"dot_fps_jump"), "and the wheel does not jump")
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	_check(settings.menu.handle_event(h) and settings.menu.help.is_open(), "H opens the help screen")
	_check(settings.menu.help.about != "" and settings.menu.help.heading() == "How to play Deathrun",
		"which says what the game is before the keys")
	settings.menu.help.close()
	settings.open()
	var help_button := settings.menu.screen.find_child("Action_help", true, false) as Button
	var leave_button := settings.menu.screen.find_child("Action_leave", true, false) as Button
	_check(help_button != null and leave_button != null and leave_button.visible,
		"the Escape menu has Help & commands and Leave")
	settings.close()
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## The family's rule since the first play test: M opens the course list, and solo a choice
## changes it now. The server's half (the owner's flag, the vote) is in `dedicated` and dot-vote.
## Offline the world samples the local player's movement itself, so the client's buttons
## have to go onto that sample. They were stamped on the controller's command and then sampled
## over, and offline no trigger ever reached the world's gun (game-zombie-zone's play test).
func _test_offline_trigger() -> void:
	_section("offline, the client's trigger reaches the world's gun")
	var game := await _world()
	var me := game.add_player(&"local", "You", 0, true)
	await _step(game, 2)
	var client := DrClient.new()
	client.game = game
	client._adopt(me)
	client._firing = true
	me.simulate(game.current_tick() + 1, 1.0 / float(TICK_RATE))
	var pressed := game.weapon_command_for(me).is_pressed(DotWeaponCommand.BUTTON_ATTACK)
	_check(me.sampler != null and pressed, "the world's weapon command has the trigger the client holds")
	client.free()
	_finished()


func _test_free_roam() -> void:
	_section("whoever is out may free-roam by default, unless an operator says otherwise")
	_check(DrConfig.new().spectate_camera == 0, "the config lets anybody be watched, so a free camera is not ruled out")
	var game := await _world()
	var a := game.add_player(&"u1", "Ada")
	var b := game.add_player(&"u2", "Bo")
	var id := a.player_id
	_check(game.spectate_rules.roaming_permitted() and game.spectate.manager.rules == game.spectate_rules,
		"the game's rules allow roaming and are the manager's own")
	a.watching = true
	game.spectate.on_died(id, b.player_id, false, Vector3(0, 2, 0), 0.0, 0)
	game.spectate.manager.set_mode(String(id), DotSpectatorView.Mode.CHASE)
	_check(game.spectate.can_roam(id), "somebody who is out may roam")
	_check(game.spectate.toggle_roam(id).ok and game.spectate.is_roaming(id), "the key enters the free camera")

	# Offline the world samples the body itself and the client stamps that sample: a roamer's
	# movement and buttons must be zeroed there too, or the keys that fly the camera also walk
	# the dead body (a previous roaming client left this gap).
	var client := DrClient.new()
	client.game = game
	client._adopt(a)
	var command := DotFpsCommand.new()
	command.move = Vector2(1.0, 1.0)
	command.set_button(DrNetCommand.BUTTON_FIRE, true)
	client._firing = true
	client._stamp(command)
	_check(command.move == Vector2.ZERO and command.buttons == 0,
		"a roamer's movement command is zeroed, offline included")
	client.free()

	var cam := DotSpectatorFreeCam.new()
	cam.rules = game.spectate_rules
	cam.seed_from(Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)))
	var pose := cam.step(Vector3(0, 0, 1), false, false, 0.5)
	_check(pose.origin.distance_to(Vector3(0, 2, 0)) > 0.5, "and flying moves it", str(pose.origin))
	_check(game.spectate.manager.move_free(String(id), pose.origin, pose.basis).ok
		and game.spectate.camera_for(id).origin.is_equal_approx(pose.origin), "the manager keeps where it is")
	_check(game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "the key again goes back to a player")

	var _off := game.spectate_rules.set_cvar("mp_freeroam", "0")
	var refused := game.spectate.toggle_roam(id)
	_check(not refused.ok and refused.error.code == DotError.CODE_FORBIDDEN and not game.spectate.is_roaming(id),
		"mp_freeroam 0 refuses it")
	var _on := game.spectate_rules.set_cvar("mp_freeroam", "1")
	var _own := game.spectate_rules.set_cvar("mp_forcecamera", "1")
	_check(not game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "mp_forcecamera 1 refuses it")

	var restricted := await _world(func(c: DrConfig) -> void:
		c.spectate_camera = 1)
	_check(restricted.spectate_rules.force_camera == 1 and not restricted.spectate_rules.roaming_permitted(),
		"a config that restricts the camera turns roaming off")
	var keys := DrBindings.make()
	_check(keys.defaults_on("G").size() == 1 and str(keys.row_for_action(DrBindings.ROAM).get("default", "")) == "G",
		"the free camera is on G, and nothing else defaults to G")
	_check(not DrEvents.write_ask_roam().is_empty() and int(DrEvents.Ask.values().max()) == DrEvents.Ask.ROAM,
		"the request is the last of the asks and carries a byte")
	_finished()


## The play test's weapons, in the end arena: the drawn rig was given the whole pack, so the slot
## held whatever was given last and never the gun the server fired; nothing counted the magazine;
## nothing said a shot had landed. Armed: with `give_everything` back the first check fails,
## without `correct_drawn` the fourth, without the HIT path the last.
func _test_the_drawn_gun() -> void:
	_section("an armed runner draws the server's gun, counted on the HUD, with a marker for a hit")
	var client: Node = (load("res://game/dr_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)
	for i in 8:
		await get_tree().process_frame
	var world: DrGame = client.get("game")
	var me: DrPlayer = client.get("player")
	var _armed := world.arm(me, ZeeWeaponIds.SMG)
	for i in 4:
		await get_tree().physics_frame

	var drawn: ZeeWeaponRig = client.get("weapons")
	var held: Array[String] = []
	var same := drawn != null and me.weapons != null and drawn != me.weapons
	for slot in range(1, 6):
		var mine := drawn.arsenal.slot_at(slot) if drawn != null else null
		var theirs := me.weapons.arsenal.slot_at(slot) if me.weapons != null else null
		var a := String(mine.def.id) if mine != null else "-"
		var b := String(theirs.def.id) if theirs != null else "-"
		held.append("%d:%s/%s" % [slot, a, b])
		same = same and a == b
	_check(same, "the drawn gun holds exactly the server's weapons, slot for slot", " ".join(held))

	var hud: Node = client.get("hud")
	hud.call("_process", 0.0)
	var counter: DotAmmoCounter = hud.get("ammo")
	var def := drawn.current_def() if drawn != null else null
	var expected := "%d | %d" % [drawn.arsenal.current().magazine, drawn.arsenal.ammo().count(def.ammo_type)] if def != null else "?"
	_check(counter != null and counter.visible and def != null and counter.weapon_name == def.display_name
		and counter.count_text() == expected,
		"the HUD has DotAmmoCounter, counting the drawn gun",
		"%s %s, want %s" % [counter.weapon_name if counter else "-", counter.count_text() if counter else "-", expected])
	_check(counter.anchor_left == 1.0 and counter.anchor_top == 1.0 and counter.offset_top >= -180.0
		and counter.offset_bottom <= -100.0,
		"it sits bottom right, above the field line and clear of the chat and the health plate")

	var world_count := me.weapons.arsenal.current().magazine
	drawn.arsenal.current().magazine = maxi(world_count - 5, 0)
	client.set("_drawn_quiet", 0.0)
	for i in 10:
		await get_tree().physics_frame
	var early := drawn.arsenal.current().magazine
	for i in 60:
		await get_tree().physics_frame
	_check(early == maxi(world_count - 5, 0) and drawn.arsenal.current().magazine == world_count,
		"the drawn gun takes the server's count once quiet, and not before",
		"after 10 ticks %d, after 70 %d, server %d" % [early, drawn.arsenal.current().magazine, world_count])

	var marker: DotHitMarker = hud.get("hit_marker")
	world.hit_landed.emit(&"local", Vector3(0.0, 1.0, -4.0), true, false)
	_check(marker != null and marker.alpha() > 0.9 and marker.kill, "a hit the world confirms flashes the marker, a kill's")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


func _test_the_map_menu() -> void:
	_section("M opens the course list, and solo a choice changes it")
	var game := await _world(func(c: DrConfig) -> void: c.course_ids = PackedStringArray())
	var _a := game.add_player(&"u1", "Ada")
	var _b := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, 2)
	var settings := DrSettings.new()
	add_child(settings)
	var _built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table defaults to M",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var rows: Array = game.course_rows()
	_check(rows.size() > 1 and rows.filter(func(r: Dictionary) -> bool: return bool(r["current"])).size() == 1,
		"there is more than one to choose, the one playing marked", "%d" % rows.size())
	var _maps := settings.use_maps(game.course_rows, game.change_course_now)
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.keycode = KEY_M
	m.pressed = true
	_check(settings.menu.handle_event(m) and settings.menu.picker.is_open(), "M opens the picker")
	var wanted: StringName = &""
	var key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = settings.menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted = StringName(str((it as Dictionary)["id"]))
			key = KEY_0 + row
			break
	var digit := InputEventKey.new()
	digit.physical_keycode = key
	digit.keycode = key
	digit.pressed = true
	var _k := settings.menu.handle_event(digit)
	for _i in 4:
		await get_tree().physics_frame
	_check(wanted != &"" and game.stage.id() == wanted, "choosing one changes to it now", "%s, now %s" % [wanted, game.stage.id()])
	_check(not settings.menu.picker.is_open(), "and the picker is closed")
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## The pack carries its art (a delivered game has only what is vendored in assets/), so every
## model the weapons table names must be here. Sync it with zee-dot-weapons' tools/sync-art.sh.
func _test_the_weapon_art_is_vendored() -> void:
	_section("every model the weapon art table names is vendored in this game")
	var models := ZeeWeaponArtTable.validate_models()
	_check(models.ok, "no weapon model is missing", "" if models.ok else models.error.message)
	_finished()


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


## A world on the practice course, stepped by hand.
##
## [b]The previous world is freed first.[/b] mg-wipeout's finding: every world here is a child
## of this node, so all of them share ONE physics space, and every course is built at the
## origin — a world left standing kept its start gate exactly where the next one's runner had
## to go.
func _world(configure: Callable = Callable()) -> DrGame:
	for old in _worlds.duplicate():
		await _dispose(old)

	var config := DrConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.course_ids = PackedStringArray(["dr_practice"])
	config.keep_progress = true

	if configure.is_valid():
		configure.call(config)

	var game := DrGame.new()
	game.name = "World%d" % _worlds.size()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	_worlds.append(game)

	# Two frames, so every collider is in the physics space before anything is asserted.
	await _physics_frame()
	await _physics_frame()
	return game


func _step(game: DrGame, ticks: int) -> void:
	for _i in range(ticks):
		game.simulate(TICK)
		await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame


func _dispose(game: DrGame) -> void:
	_worlds.erase(game)

	if not is_instance_valid(game):
		return

	remove_child(game)
	game.free()
	await get_tree().process_frame
