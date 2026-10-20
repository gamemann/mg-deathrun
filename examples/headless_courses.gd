extends Node

const DrAudio := preload("../game/dr_audio.gd")
const DrCatalogue := preload("../game/dr_catalogue.gd")
const DrConfig := preload("../game/dr_config.gd")
const DrCourse := preload("../game/dr_course.gd")
const DrCourseDoc := preload("../game/dr_course_doc.gd")
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
const BAKE_CHECKS := 4

var _passed := 0
var _failed := 0
var _sections_entered := 0
## The slowest average pace a stand-in runner may have on a course, as a share of the run speed.
## Measured: 0.81-0.95 on the five courses; before the landing brake Ice Works ran 0.72 (27.4 s), so 0.75 catches that and any walk (0.45).
const RUNNER_PACE_FLOOR := 0.75

var _sections_finished := 0
var _failures := PackedStringArray()
var _world: DrGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()

const PUSH_CHECKS := 4
const TELEPORT_CHECKS := 19


func _run() -> void:
	print("deathrun: every course played")
	print("")

	var catalogue := DrCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	var courses := catalogue.courses.keys()
	courses.sort()
	# DR_COURSES=id,id plays only those (a converted map is checked in minutes, not the whole catalogue)
	var only := OS.get_environment("DR_COURSES")
	if not only.is_empty():
		var wanted := only.split(",")
		courses = courses.filter(func(id: StringName) -> bool: return wanted.has(str(id)))

	if courses.size() <= 1:
		print("(no course directory: the built-in practice course only)")

	_section("every document loads")
	_check(catalogue.refused.is_empty(), "none was refused", str(catalogue.refused))
	_check_machinery(catalogue)
	_check_facing(catalogue)
	_check_sound_ids()
	_finished()

	_test_baked_light(catalogue)
	await _test_push_zone(catalogue)
	await _test_teleport_pad(catalogue)

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
		await _audit_collision(doc)

	if _world != null:
		remove_child(_world)
		_world.free()

	var sections := 4 + courses.size() * 5
	var checks := 5 + PUSH_CHECKS + TELEPORT_CHECKS + BAKE_CHECKS + courses.size() * (3 + 1 + 4 + 1) + traps + spared

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


## A teleport pad sends whoever stands on it to its `to`, facing its `heading`, and nobody beside
## it, a jump above it or under it; `for` keeps one side from using it.
func _test_teleport_pad(catalogue: DrCatalogue) -> void:
	_section("a teleport pad")
	var doc: Dictionary = (catalogue.courses[&"dr_practice"] as Dictionary).duplicate(true)
	var made := DrCourseDoc._piece({
		"kind": "teleport", "at": [0.0, 0.0, 0.0], "size": [4.0, 0.2, 4.0], "to": [50.0, 5.0, 60.0],
		"heading": 90.0, "for": "runners",
	}, (doc["pieces"] as Array).size())
	_check(made.ok, "a teleport piece validates", str(made.error) if not made.ok else "")

	if not made.ok:
		for i in range(TELEPORT_CHECKS - 1):
			_check(false, "teleport check skipped", "the piece did not validate")
		_finished()
		return

	var game := await _fresh(doc)
	(game.catalogue.courses[doc["id"]]["pieces"] as Array).append(made.value)
	game._lay_out_course()
	var top := Vector3(0.0, 0.1, 0.0)
	var sent: Array = game.stage.teleport_at(top)
	_check(sent.size() == 3 and (sent[0] as Vector3).is_equal_approx(Vector3(50.0, 5.0, 60.0)) \
		and is_equal_approx(float(sent[1]), 90.0), "on it, a runner is sent to its destination", str(sent))
	_check(game.stage.teleport_at(top, false).is_empty(), "a pad for runners does not send an activator")
	_check(game.stage.teleport_at(top + Vector3(0.0, 2.5, 0.0)).is_empty(), "two and a half metres above it, nobody is")
	_check(game.stage.teleport_at(top + Vector3(3.0, 0.0, 0.0)).is_empty(), "three metres beside it, nobody is")

	# A destination inside a teleport would send them on again every tick: the document is refused.
	var looped: Dictionary = (catalogue.courses[&"dr_practice"] as Dictionary).duplicate(true)
	var loop_pad: Dictionary = made.value.duplicate(true)
	loop_pad["to"] = Vector3(0.0, 0.1, 0.0)
	(looped["pieces"] as Array).append(loop_pad)
	_check(not DrCourseDoc.validate(looped).ok, "a teleport that lands inside a teleport is refused")

	# Destinations the validator refuses, each against a control that passes.
	var base: Dictionary = (catalogue.courses[&"dr_practice"] as Dictionary).duplicate(true)
	var solid_pad: Dictionary = made.value.duplicate(true)
	solid_pad["to"] = Vector3(30.0, 0.1, 30.0)
	var box: Dictionary = DrCourseDoc._piece({"kind": "box", "at": [20.0, 1.0, 20.0], "size": [4.0, 2.0, 4.0]}, 0).value
	var ahead_volume: Dictionary = DrCourseDoc._piece({"kind": "teleport", "at": [0.0, 1.0, 4.0], "size": [1.0, 2.0, 1.0],
		"to": [40.0, 0.1, 40.0], "heading": 0.0, "solid": false}, 0).value
	var cases := {
		"lands above a solid pad": [{"to": Vector3(0.0, 2.0, 0.0)}, []],
		"lands inside solid geometry": [{"to": Vector3(20.0, 1.0, 20.0)}, [box]],
		"lands below the kill height": [{"to": Vector3(30.0, -50.0, 30.0)}, []],
		"keeps speed towards a volume": [{"to": Vector3(0.0, 0.1, 7.0), "keep": true, "heading": 0.0}, [ahead_volume]],
	}
	var control := base.duplicate(true)
	(control["pieces"] as Array).append(solid_pad)
	_check(DrCourseDoc.validate(control).ok, "a teleport to open floor passes the validator", str(DrCourseDoc.validate(control).error))

	for label: String in cases:
		var bad := base.duplicate(true)
		var candidate := solid_pad.duplicate(true)
		candidate.merge((cases[label] as Array)[0], true)
		(bad["pieces"] as Array).append_array((cases[label] as Array)[1])
		(bad["pieces"] as Array).append(candidate)
		_check(not DrCourseDoc.validate(bad).ok, "the validator refuses a teleport that " + label)

	# Trigger volumes, walked into: one that zeroes velocity, one that keeps it.
	var stop: Dictionary = DrCourseDoc._piece({"kind": "teleport", "at": [-1.8, 1.0, 4.0], "size": [1.0, 2.0, 1.0],
		"to": [1.5, 0.1, 6.5], "heading": 180.0, "solid": false}, 0).value
	var keep: Dictionary = DrCourseDoc._piece({"kind": "teleport", "at": [1.8, 1.0, 4.0], "size": [1.0, 2.0, 1.0],
		"to": [0.0, 0.1, 7.0], "heading": 0.0, "solid": false, "keep": true}, 0).value
	(game.catalogue.courses[doc["id"]]["pieces"] as Array).append_array([stop, keep])
	game._lay_out_course()
	_check(game.stage.teleport_at(Vector3(-1.8, 1.9, 4.0)).size() == 3 and game.stage.teleport_at(Vector3(-1.8, 2.6, 4.0)).is_empty(),
		"a trigger volume sends whoever is inside its box, and not above it")
	var runner := game.add_player(&"u1", "Runner")
	var activator := game.add_player(&"u3", "Activator")
	await _begin(game, [runner], [activator])
	await _ticks(game, int((game.config.countdown_seconds + 0.2) * TICK_RATE))
	runner.place_at(Vector3(-1.8, 0.1, 4.0), 0.0)
	runner.controller.state.velocity = Vector3(0.0, 0.0, -5.0)
	await _ticks(game, 1)
	var there := runner.controller.state.position
	_check(Vector2(there.x - 1.5, there.z - 6.5).length() < 0.3 and absf(angle_difference(deg_to_rad(runner.controller.state.yaw), PI)) < 0.1,
		"a runner who is in it is sent by their own tick, facing its heading", "%s yaw %.0f" % [there, runner.controller.state.yaw])
	_check(Vector2(runner.controller.state.velocity.x, runner.controller.state.velocity.z).length() < 0.5,
		"and lands still", str(runner.controller.state.velocity))
	_check(runner.controller._previous_state.position.distance_to(there) < 0.01,
		"and the render blend starts from the landing, not from where they were", str(runner.controller._previous_state.position))
	# A runner who has finished walks the end arena freely: a volume does not send them.
	runner.at_end = true
	runner.place_at(Vector3(-1.8, 0.1, 4.0), 0.0)
	await _ticks(game, 1)
	_check(runner.controller.state.position.distance_to(Vector3(-1.8, 0.1, 4.0)) < 0.6 and not runner.teleported,
		"a runner who has finished is not sent", str(runner.controller.state.position))
	runner.at_end = false
	runner.place_at(Vector3(1.8, 0.1, 4.0), 0.0)
	runner.controller.state.velocity = Vector3(0.0, 0.0, -5.0)
	await _ticks(game, 1)
	_check(runner.controller.state.position.distance_to(Vector3(0.0, 0.1, 7.0)) < 0.4
			and Vector2(runner.controller.state.velocity.x, runner.controller.state.velocity.z).length() > 3.0,
		"one that keeps velocity lands moving", str(runner.controller.state.velocity))
	# A replayed warp must not re-aim the mouse: a correction re-runs old ticks.
	var sampler := DotFpsSampler.new(runner.controller.tunables)
	runner.controller.sampler = sampler
	runner.place_at(Vector3(-1.8, 0.1, 4.0), 0.0)
	sampler.look_at_angles(33.0, 5.0)
	runner.controller.begin_replay()
	await _ticks(game, 1)
	runner.controller.end_replay()
	_check(runner.warps > 0 and is_equal_approx(sampler.yaw, 33.0),
		"a warp replayed in a correction leaves the player's look alone", "%.1f" % sampler.yaw)
	runner.place_at(Vector3(-1.8, 0.1, 4.0), 0.0)
	await _ticks(game, 1)
	_check(absf(angle_difference(deg_to_rad(sampler.yaw), PI)) < 0.1,
		"and a fresh one turns it to the heading", "%.1f" % sampler.yaw)
	runner.controller.sampler = null
	_finished()


## A push zone moves a runner standing in it while its trap is out, the way its `push` says and
## no other, and leaves them alone before the press and outside the box. Armed: the first check
## fails if the zone pushed nobody, the second if it pushed before the press.
func _test_push_zone(catalogue: DrCatalogue) -> void:
	_section("a push zone")
	var doc: Dictionary = (catalogue.courses[&"dr_practice"] as Dictionary).duplicate(true)
	var made := DrCourseDoc._trap({
		"id": "push_test", "button": {"at": [0.0, 1.0, 0.0]},
		"timing": {"delay": 0.0, "out": 0.1, "hold": 6.0, "back": 0.5},
		"parts": [{"at": [0.0, 0.0, 0.0], "size": [2000.0, 200.0, 2000.0], "push": [3.0, 0.0, 0.0], "look": "wind"}],
	}, (doc["traps"] as Array).size())
	_check(made.ok and not bool(made.value["parts"][0]["solid"]) and not bool(made.value["parts"][0]["lethal"]),
		"a push part validates, and is neither solid nor lethal", str(made.error) if not made.ok else "")

	if not made.ok:
		for i in range(PUSH_CHECKS - 1):
			_check(false, "push zone check skipped", "the trap did not validate")
		_finished()
		return

	# A zone far bigger than the course, so wherever the round puts the runner they are in it.
	var game := await _fresh(doc)
	var patched: Dictionary = game.catalogue.courses[doc["id"]]
	(patched["traps"] as Array).append(made.value)
	game._lay_out_course()
	var runner := game.add_player(&"u1", "Runner")
	var activator := game.add_player(&"u3", "Activator")
	await _begin(game, [runner], [activator])
	await _ticks(game, int((game.config.countdown_seconds + 0.2) * TICK_RATE))
	var index := game.stage.trap_index("push_test")
	var before := runner.controller.state.position
	await _ticks(game, TICK_RATE)
	var idle := runner.controller.state.position - before
	_check(absf(idle.x) < 0.05, "before the press, nobody is pushed", str(idle))

	var pressed := game.press(index, activator.player_id)
	var from := runner.controller.state.position
	await _ticks(game, TICK_RATE * 2)
	var moved := runner.controller.state.position - from
	_check(pressed and moved.x > 2.0 and absf(moved.z) < 0.3 and absf(moved.y) < 0.3,
		"pressed, the runner in the zone is pushed along its direction", "pressed %s, moved %s" % [pressed, moved])
	_check(game.stage.push_at(Vector3(0.0, 0.0, 9000.0), false, game._tick) == Vector3.ZERO,
		"and a point outside it is not pushed")
	_finished()


## The committed bakes against the courses as they are now. A course edited without a rebake
## still plays (the live sun alone and a WARN on every client), so nothing else would notice:
## this does. Rebake with tools/bake_lightmaps.sh. Headless, a bake's pixels are not loaded, but
## its fingerprint is, and attaching is refused without touching the course.
func _test_baked_light(catalogue: DrCatalogue) -> void:
	_section("baked light")
	var stale := PackedStringArray()
	var baked := PackedStringArray()

	for id: StringName in catalogue.courses:
		var path := DrCourse.BAKE_PATH % String(id)

		if not ResourceLoader.exists(path):
			continue

		var course := DrCourse.new()
		var _built := course.build(catalogue.courses[id])
		var data := load(path) as LightmapGIData
		baked.append(String(id))

		if data == null or str(data.get_meta(DotLightBake.META_FINGERPRINT, "")) != course.light_fingerprint():
			stale.append(String(id))

		course.free()

	_check(stale.is_empty(), "every committed bake was made from its course as it is now",
		"baked %s, stale %s" % [baked, stale])
	_check(baked.has("dr_practice"), "the practice course, the one every build has, ships a bake")

	var moved := DrCourse.new()
	var doc: Dictionary = (catalogue.courses[&"dr_practice"] as Dictionary).duplicate(true)
	var _built_first := moved.build(doc)
	var before := moved.light_fingerprint()
	var shifted := false

	for spec: Dictionary in moved.doc["pieces"]:
		if DrCourse.is_bakeable(spec, str(spec["kind"])):
			spec["at"] = (spec["at"] as Vector3) + Vector3(0.25, 0.0, 0.0)
			shifted = true
			break

	# A mover moving is not a change of the bake; a still box moving is.
	_check(shifted and moved.light_fingerprint() != before, "moving one still box makes the bake stale (the fingerprint changes)")

	var host := Node3D.new()
	add_child(host)
	var res := DotLightBake.attach(host, DrCourse.BAKE_PATH % "dr_practice", before)
	_check(not res.ok and res.error.code == DotError.CODE_UNSUPPORTED and host.get_child_count() == 0,
		"a headless process (a server) never lays a bake over its course", "%s" % [res.error.message if not res.ok else "attached"])
	host.free()
	moved.free()
	_finished()


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


## [method DrAudio.ids] is every sound the catalogue knows, both ways: a sound in the catalogue
## and not in the list is one a preload or a listing misses (the four death sounds were, until
## 2026-10-12).
func _check_sound_ids() -> void:
	var listed := {}
	for id: StringName in DrAudio.ids():
		listed[id] = true
	var known := {}
	for id: StringName in DrAudio.sound_catalogue().ids():
		known[id] = true
	var missing := PackedStringArray()
	for id: StringName in known:
		if not listed.has(id):
			missing.append("unlisted " + String(id))
	for id: StringName in listed:
		if not known.has(id):
			missing.append("uncatalogued " + String(id))
	_check(missing.is_empty() and listed.has(DotPlayerDeathReactions.SOUND_FACE_PLANT),
		"every catalogued sound is listed, the death sounds too", ", ".join(missing))


## A freshly placed player faces the course, and can see it past the closed gate.
##
## The game-vote harness's frames of a player who had just joined deathrun were an orange wall
## (2026-10-11). The spawn faced the course; the wall was the start gate, opaque, 1.4 m in
## front of the front row for all of warmup. So both halves: the yaw every runner and activator
## is placed with points down the course (at the finish), and the gate is see-through.
func _check_facing(catalogue: DrCatalogue) -> void:
	var wrong := PackedStringArray()

	for id: StringName in catalogue.courses:
		var doc: Dictionary = catalogue.courses[id]
		var finish: Vector3 = doc["finish"]["at"]
		# A course that bends (an imported ring) is faced down its first leg: the first route point
		# is where the runners go, and the finish is round a corner.
		var route: Array = doc.get("route", [])
		var heading: Vector3 = route[mini(1, route.size() - 1)]["at"] if not route.is_empty() else finish

		for area in ["start", "activators"]:
			for seat in range(3):
				var spot := DrCourse.spot_in(doc[area], seat, 3)
				var facing := Basis(Vector3.UP, deg_to_rad(float(spot[1]))) * Vector3.FORWARD
				var ahead := (heading if area == "start" else finish) - (spot[0] as Vector3)
				ahead.y = 0.0
				var along := facing.dot(ahead.normalized())

				if along < 0.9:
					wrong.append("%s %s seat %d: yaw %.0f, %.2f toward the finish" % [
						id, area, seat, float(spot[1]), along
					])

	_check(wrong.is_empty(), "every runner and activator is placed facing down the course",
		"; ".join(wrong) if not wrong.is_empty() else "%d courses" % catalogue.courses.size())

	var gate := DrCourse.gate_material()
	_check(gate.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED and gate.albedo_color.a < 0.6,
		"the start gate is see-through, so the front row sees the course and not a wall",
		"alpha %.2f" % gate.albedo_color.a)


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
	var start_at := bot.controller.state.position

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

	# Average pace, not top speed: a bot that reaches 7 m/s for a moment and spends the rest
	# settling, braking or waiting reads as a runner walking. The distance is the route's
	# own length, so a course's jumps and landings are counted in the pace.
	var average := _route_length(game, start_at) / maxf(finished_at, 0.01)
	print("PACE %s: %.2f m/s over %.1f s" % [doc["id"], average, finished_at])
	_check(finished_at > 0.0 and average >= game.config.run_speed * RUNNER_PACE_FLOOR,
		"its average pace on the course is a runner's, not a walk",
		"%.2f m/s of %.1f run speed (floor %.0f%%)" % [average, game.config.run_speed, RUNNER_PACE_FLOOR * 100.0])
	_finished()


## The flat length of a runner's route from [param from] through every point.
func _route_length(game: DrGame, from: Vector3) -> float:
	var total := 0.0
	var last := from

	for point in game.stage.route():
		var at: Vector3 = (point as Dictionary)["at"]
		total += Vector2(at.x - last.x, at.z - last.z).length()
		last = at

	return total


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

		# 15 s, and the time a run at about 5 m/s takes for a long way between two buttons
		var budget := TICK_RATE * (15 + int(maxf(0.0, Vector2(button.x - activator.eye_position().x, button.z - activator.eye_position().z).length() - 60.0) / 5.0))
		# a walkway's own length is walked too, to the button and (for the next) back or on
		var walkway := game.stage.walkway()
		for w in range(1, walkway.size()):
			budget += int(TICK_RATE * ((walkway[w]["at"] as Vector3).distance_to(walkway[w - 1]["at"]) / 4.0))

		for i in range(budget):
			var eyes := activator.eye_position()
			var look := button - eyes
			var command := DotFpsCommand.new()
			command.yaw = rad_to_deg(atan2(-look.x, -look.z))
			command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)

			# The stand-in's own walk (the course's walkway, or straight): the check is that it works.
			if not game.bot_walk_toward(activator, index, command):
				pass
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

	# The course's toys (dot-props', loose only): all built, none inside a piece, and after the
	# seconds this section has run every one still where the course put it.
	var box := game.stage.toys
	var placed := (doc.get("toys", []) as Array).size()
	var stuck: Array = []
	var space := game.get_world_3d().direct_space_state
	for toy in box.toys:
		for child in toy.body.get_children():
			var shape := child as CollisionShape3D
			if shape == null or shape.shape == null:
				continue
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = shape.shape
			query.transform = shape.global_transform.translated(Vector3(0, 0.05, 0))
			query.collision_mask = game.physics.layer_mask(&"world")
			if not space.intersect_shape(query, 1).is_empty():
				stuck.append("%s %d at %s" % [toy.def["id"], toy.index, toy.global_position.snapped(Vector3.ONE * 0.1)])
				break
	_check(box.count() == placed and placed > 0 and box.missing.is_empty() and stuck.is_empty(),
		"%d toys, every one dot-props', standing clear" % placed, "; ".join(stuck))
	var strayed: Array = []
	for toy in box.toys:
		if toy.body.global_position.distance_to(toy.rest.origin) > 0.6:
			strayed.append("%s %d to %s" % [toy.def["id"], toy.index, toy.body.global_position.snapped(Vector3.ONE * 0.1)])
	_check(strayed.is_empty(), "and every toy is still where the course put it", "; ".join(strayed))
	_finished()


# --- Helpers ------------------------------------------------------------------------

## dot-core's [DotCollisionAudit] over the course as a client draws it: visible geometry nothing
## collides with, which a runner walks through. The course keeps its drawing and its bodies
## apart (moving parts are static bodies the course teleports), so the lenient audit is used.
func _audit_collision(doc: Dictionary) -> void:
	_section("%s: nothing drawn is walked through" % doc["id"])
	var game := await _fresh(doc, true)
	var res := DotCollisionAudit.audit(game.stage, true)
	var found := 0

	if res.ok:
		var report: DotCollisionAudit = res.value
		found = report.count()
		print("  %s collision audit: %d of %d" % [doc["id"], found, report.examined])

		for line in report.describe_lines().slice(1, 12):
			print("    %s" % line)

	_check(res.ok and found == 0, "no drawn geometry without a shape", "" if res.ok else res.error.message)
	_finished()


func _fresh(doc: Dictionary, drawn := false) -> DrGame:
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
	_world.draw_world = drawn
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
