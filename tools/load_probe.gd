extends SceneTree

const DrClient := preload("../game/dr_client.gd")

## Boots the solo client and prints, per frame, what a player would see and whether the load
## gate still covers it. Needs xvfb-run: `godot --path . --script tools/load_probe.gd -- [--frames=90] [--shot=N]`
var _client: Node = null
var _frame := 0
var _frames := 90
var _shot := -1
var _last := Vector3.ZERO
var _was_covered := true


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			_frames = int(a.get_slice("=", 1))
		if a.begins_with("--shot="):
			_shot = int(a.get_slice("=", 1))
	DirAccess.make_dir_recursive_absolute("res://screenshots")
	_client = DrClient.new()
	_client.set("force_offline", true)
	root.add_child(_client)


func _process(_delta: float) -> bool:
	_frame += 1
	var gate: Object = _client.get("gate")
	var covered: bool = gate != null and not gate.is_open()
	var player: Object = _client.get("player")
	var pos: Vector3 = player.global_position if player != null else Vector3.ZERO
	var cam: Object = _client.get("camera")
	var moved := pos.distance_to(_last)
	_last = pos
	print("frame %3d gate=%s covered=%s phase=%s tick=%s player=%s cam=%s hud=%s pos=%s moved=%.3f" % [
		_frame, gate != null, covered, _client.get("game").phase, _client.get("game").current_tick(), player != null,
		cam != null and cam.is_inside_tree(), _client.get("hud") != null, pos, moved])
	var lifted := _was_covered and not covered
	_was_covered = covered
	if _frame == _shot or (_shot < 0 and (_frame == 4 or lifted)):
		get_root().get_viewport().get_texture().get_image().save_png(
			ProjectSettings.globalize_path("res://screenshots/load_probe_%d.png" % _frame))
	if _frame >= _frames:
		quit(0)
	return false
