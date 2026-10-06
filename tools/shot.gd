extends Node

## Renders the game and saves a frame. The check no assertion in this repository makes.
##
##   tools/shot.sh                                  # a runner's own eyes, a few seconds in
##   tools/shot.sh --view=course --dr-course-ids=dr_ice_works   # a course, from above
##   tools/shot.sh --view=start                     # the start, from behind the runners
##   tools/shot.sh --view=activator                 # the walkway, from the activator's eyes
##   tools/shot.sh --view=trap --trap=ice_jaws --after=0.5   # a trap, half a second after its press
##   tools/shot.sh --view=third                     # third person, mid-course
##   tools/shot.sh --view=end                       # the end arena, from a runner who made it
##
## Any `--dr-*` is the game's own configuration (see `DrConfig`), because `DrClient` reads it.

const DrClient := preload("../game/dr_client.gd")
const DrGame := preload("../game/dr_game.gd")

var _view := "eyes"
var _seconds := 4.0
var _out := "res://screenshots/shot.png"
var _trap := ""
var _after := 0.5
var _client: Node = null


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
		elif arg.begins_with("--seconds="):
			_seconds = arg.trim_prefix("--seconds=").to_float()
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--trap="):
			_trap = arg.trim_prefix("--trap=")
		elif arg.begins_with("--after="):
			_after = arg.trim_prefix("--after=").to_float()

	_client = DrClient.new()
	_client.name = "Client"
	_client.set("force_offline", true)
	_client.set("third_person", _view == "third")
	add_child(_client)
	_run.call_deferred()


func _run() -> void:
	var game: DrGame = _client.get("game")
	# Into a round, with the person at this keyboard on the side the view is about. The
	# stand-ins are left where the draw put them, except that none of them presses anything
	# the picture did not ask for.
	await _until_a_round(game)
	var local = _client.get("player")
	var activator := _view == "activator"

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
			_free_camera().look_at_from_position(eye, victim + Vector3(0.0, 0.9, 0.0))
		"end":
			await _seconds_of(game.config.countdown_seconds + 0.5)
			local.place_at(game.course_doc["finish"]["at"], 0.0)
			await _seconds_of(1.5)
		_:
			await _seconds_of(_seconds)

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
