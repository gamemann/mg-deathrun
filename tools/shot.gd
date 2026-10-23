extends Node

## Renders the game and saves a frame. The check no assertion in this repository makes.
##
##   tools/shot.sh                                  # a runner's own eyes, a few seconds in
##   tools/shot.sh --view=course --dr-course-ids=dr_ice_works   # a course, from above
##   tools/shot.sh --view=start                     # the start, from behind the runners
##   tools/shot.sh --view=activator                 # the walkway, from the activator's eyes
##   tools/shot.sh --view=button                    # the activator at a button: the key prompt
##   tools/shot.sh --view=button --spent            # ...once that trap is spent
##   tools/shot.sh --view=trap --trap=ice_jaws --after=0.5   # a trap, half a second after its press
##   tools/shot.sh --view=third                     # third person, mid-course
##   tools/shot.sh --view=cover                     # the loading cover, before it lifts
##   tools/shot.sh --view=end                       # the end arena, from a runner who made it
##   tools/shot.sh --view=killcam --seconds=2       # the round's last moment replayed; --seconds=7.5 for the podium
##
## Any `--dr-*` is the game's own configuration (see `DrConfig`), because `DrClient` reads it.

const DrCourseDoc := preload("../game/dr_course_doc.gd")
const DrCatalogue := preload("../game/dr_catalogue.gd")
const DrClient := preload("../game/dr_client.gd")
const DrCourse := preload("../game/dr_course.gd")
const DrGame := preload("../game/dr_game.gd")

var _view := "eyes"
var _seconds := 4.0

## `--board`: the Tab scoreboard held open over the frame.
var _board: bool = false

## How long `--view=end` waits after arriving; `--end-wait=N`.
var _end_wait := 1.5
## `--fire=N`: at the end, the trigger held for N seconds before the frame (the flash, the
## tracer and the impact in it, and the counter down).
var _fire := 0.0
var _out := "res://screenshots/shot.png"
var _trap := ""
var _after := 0.5
## `--eye=x,y,z`: where the trap view's camera stands, metres from the victim (the default assumes a corridor running along -Z, which a converted map's corridor does not)
var _eye_offset := Vector3.INF
## `--spent`: `--view=button` presses the trap first, so the prompt says it is spent.
var _spent := false
var _client: Node = null


## --view=maps: a fixture course pack in the shared [DotContentIndex], as the solo shell leaves
## one after a subscribed pack mounts, so the M menu shows what a player would see. The pack's
## course is the practice course under another name, written to user://.
func _subscribe_fixture() -> void:
	var dir := "user://ws_shot_dr/"
	DirAccess.make_dir_recursive_absolute(dir)
	var doc := DrCatalogue.practice().duplicate(true)
	doc["id"] = "fixture_pit"
	doc["name"] = "Fixture Pit"
	doc["blurb"] = "From the Workshop."
	var file := FileAccess.open(dir + "pit.json", FileAccess.WRITE)
	file.store_string(DrCourseDoc.to_json(doc))
	file.close()
	var index := DotContentIndex.shared()
	index.set_session(DotContentIndex.SESSION_SOLO)
	var _added := index.add_pack({
		"content_id": "fixture/pits", "version": "1.0.0", "prefix": dir,
		"session": DotContentIndex.SESSION_SOLO, "source": &"subscription",
		"provides": {"schema": 1, "title": "Hilltop Pack", "kinds": ["map"], "entries": [
			{"kind": "map", "id": "fixture_pit", "name": "Fixture Pit", "scene": "pit.json", "map_kind": "deathrun"},
			{"kind": "map", "id": "fixture_run", "name": "Fixture Run", "scene": "pit.json", "map_kind": "surf"},
		]},
	})


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--no-bake":
			DrCourse.use_bakes = false
		elif arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
		elif arg == "--spent":
			_spent = true
		elif arg == "--board":
			_board = true
		elif arg.begins_with("--end-wait="):
			_end_wait = arg.trim_prefix("--end-wait=").to_float()
		elif arg.begins_with("--fire="):
			_fire = arg.trim_prefix("--fire=").to_float()
		elif arg.begins_with("--seconds="):
			_seconds = arg.trim_prefix("--seconds=").to_float()
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--trap="):
			_trap = arg.trim_prefix("--trap=")
		elif arg.begins_with("--eye="):
			var parts := arg.trim_prefix("--eye=").split_floats(",")
			if parts.size() == 3:
				_eye_offset = Vector3(parts[0], parts[1], parts[2])
		elif arg.begins_with("--after="):
			_after = arg.trim_prefix("--after=").to_float()

	if _view == "maps":
		_subscribe_fixture()

	_client = DrClient.new()
	_client.name = "Client"
	_client.set("force_offline", true)
	_client.set("third_person", _view == "third")
	add_child(_client)
	# --view=cover: the loading cover dot-game's DotGameClient puts up first, before it lifts.
	if _view == "cover":
		for _i in 2:
			await RenderingServer.frame_post_draw
		var platform: DotGameClient = _client.get("platform")
		print("cover %s" % ("lifted" if platform.is_shown() else "up"))
		var cover_path := ProjectSettings.globalize_path(_out)
		DirAccess.make_dir_recursive_absolute(cover_path.get_base_dir())
		print("saved %s: %s" % [_out, error_string(_client.get_viewport().get_texture().get_image().save_png(cover_path))])
		get_tree().quit(0)
		return
	_run.call_deferred()


func _run() -> void:
	var game: DrGame = _client.get("game")
	# Into a round, with the person at this keyboard on the side the view is about. The
	# stand-ins are left where the draw put them, except that none of them presses anything
	# the picture did not ask for.
	await _until_a_round(game)
	var local = _client.get("player")
	var activator := _view == "activator" or _view == "button"

	# One activator: the person at this keyboard for the activator's view, a stand-in otherwise.
	var drawn := false

	for id: StringName in game.players:
		var body = game.players[id]
		var side := DrGame.RUNNERS

		if body == local:
			side = DrGame.ACTIVATORS if activator else DrGame.RUNNERS
		elif not activator and not drawn:
			side = DrGame.ACTIVATORS
			drawn = true

		game._set_side(id, side)

	game._place_everybody()

	if _view != "eyes" and _view != "third":
		for id: StringName in game.players:
			game.players[id].is_bot = false

	match _view:
		"course":
			await _frames(6)
			var box: AABB = game.stage.bounds()
			var centre := box.get_center()
			var reach := maxf(box.size.length() * 0.5, 14.0)
			_free_camera().look_at_from_position(centre + Vector3(reach * 0.55, reach * 0.55, reach * 0.15), centre)
		"start":
			await _seconds_of(0.6)
			var start: Vector3 = game.course_doc["start"]["at"]
			_free_camera().look_at_from_position(start + Vector3(0.0, 2.6, 2.6), start + Vector3(0.0, 0.6, -14.0))
		"activator":
			# At the rail, where an activator watches from.
			var at: Vector3 = local.controller.state.position
			local.place_at(Vector3(4.2, at.y, at.z - 6.0), 0.0)
			await _seconds_of(_seconds)
			var eyes: Vector3 = local.eye_position()
			_free_camera().look_at_from_position(eyes, eyes + Vector3(-3.2, -2.6, -8.0))
		"button":
			# The activator a step in front of the first button, facing it through their own
			# camera, so the HUD's prompt is the one the client draws for that aim.
			await _seconds_of(game.config.countdown_seconds + 0.3)
			var post: Vector3 = game.stage.button_point(0) - Vector3(0.0, 1.0, 0.0)
			local.place_at(Vector3(post.x, local.controller.state.position.y, post.z + 1.2), 0.0)
			if _spent:
				var _pressed := game.press(0, local.player_id)
			await _seconds_of(0.6)
		"trap":
			await _seconds_of(game.config.countdown_seconds + 0.3)
			var index: int = game.stage.trap_index(_trap) if _trap != "" else 0
			index = maxi(index, 0)
			var victim: Vector3 = (game.stage.traps[index]["spec"] as Dictionary).get("victim",
				game.stage.trap_zone(index).get_center())
			# Somebody standing in it, so the picture says what it does to a person.
			for id: StringName in game.players:
				var body = game.players[id]
				if game.team_of(id) == DrGame.RUNNERS and body != local:
					body.place_at(victim + Vector3(0.0, 0.1, 0.0), 0.0)
					break
			await _seconds_of(0.3)
			var _pressed := game.press(index, local.player_id if game.team_of(local.player_id) == DrGame.ACTIVATORS \
				else game.players_on(DrGame.ACTIVATORS)[0].player_id)
			await _seconds_of(_after)
			# Behind them and up, inside the corridor whichever side they are on: an offset to one
			# side put the camera in the wall for a trap on the left half.
			var eye := Vector3(clampf(-victim.x * 0.6, -2.4, 2.4), victim.y + 2.6, victim.z + 6.5)
			if _eye_offset != Vector3.INF:
				eye = victim + _eye_offset
			_free_camera().look_at_from_position(eye, victim + Vector3(0.0, 0.9, 0.0))
		"maps":
			# M: the solo course list, with the Workshop's course among the game's own.
			await _seconds_of(0.5)
			var settings: Object = _client.get("settings")
			var menu: Variant = settings.get("menu")
			menu.call(&"open_maps")
			var picker: Variant = menu.get("picker")
			if picker != null:
				# Past the last row and back one: the fixture sorts after the shipped courses' ids.
				var rows := game.course_rows()
				for i in range(rows.size()):
					if str(rows[i]["id"]) == "fixture_pit":
						picker.call(&"turn", 99)
						picker.call(&"turn", i - rows.size() + 1)
			await _seconds_of(_seconds)
		"killcam", "reveal":
			# A runner caught by a trap and the round decided; --seconds is how long after, so
			# ~2 is the replay and ~7.5 the podium.
			await _seconds_of(game.config.countdown_seconds + 3.0)
			game._kill(local, 0, DrGame.DIED_TRAP)
			game._decide(DrGame.ACTIVATORS, "the activators win")
			await _seconds_of(_seconds)
		"end":
			await _seconds_of(game.config.countdown_seconds + 0.5)
			local.place_at(game.course_doc["finish"]["at"], 0.0)
			# `--end-wait=N` waits longer at the end: the weapon is handed over on arrival and
			# its deploy is still running at 1.5 s.
			await _seconds_of(maxf(1.5, _end_wait))
			if _fire > 0.0:
				_client.set("_firing", true)
				await _seconds_of(_fire)
		_:
			await _seconds_of(_seconds)

	if _board:
		var menu: Variant = _client.get("settings").menu
		var tab := InputEventKey.new()
		tab.physical_keycode = KEY_TAB
		tab.pressed = true
		menu.handle_event(tab)

	await _frames(3)
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(_out)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var saved := image.save_png(path)
	print("saved %s (%s): %s" % [_out, _view, error_string(saved)])
	get_tree().quit(0 if saved == OK else 1)


func _until_a_round(game: DrGame) -> void:
	for _i in range(600):
		if game.phase == DrGame.Phase.COUNTDOWN and _client.get("player") != null:
			return
		await get_tree().process_frame


func _free_camera() -> Camera3D:
	var camera := Camera3D.new()
	camera.fov = 75.0
	add_child(camera)
	camera.current = true
	return camera


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _seconds_of(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
