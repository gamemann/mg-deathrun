extends DotGameCheckSuite

const DrConfig := preload("../game/dr_config.gd")
const DrMapConfig := preload("../game/dr_map_config.gd")

## A course's file sets the game's rules and the next course puts them back, on the server's cvars and on the client's own config.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapcfg.tscn
## [/codeblock]
##
## The files are written to a scratch operator tier, so the rules start away from them.

const CHECKS := 9


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-deathrun: per-course rules from cfg/game/mg-deathrun/dot_map/map")
	if not ResourceLoader.exists(DotGameMapConfig.SCRIPT_PATH):
		print("SKIPPED: dot-map is not linked at addons/dot_map")
		get_tree().quit(0)
		return
	var root := ProjectSettings.globalize_path("user://mapcfg_check")
	var dir := root.path_join("server/game/%s/dot_map/map" % DrMapConfig.GAME)
	DirAccess.make_dir_recursive_absolute(dir)
	_write(dir.path_join("dr_icy.yml"), "dr_gravity: 12.0\ndr_round_seconds: 120\ndr_autobhop: false\nsv_gravity: 1\n")
	DotAddonConfig.game = DrMapConfig.GAME

	var console := DotConsole.new()
	add_child(console)
	console.cvar("dr_gravity", "20", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("dr_round_seconds", "300", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("dr_autobhop", "1", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("sv_gravity", "800", "", DotConVar.FLAG_ARCHIVE)
	var cfg := DotGameMapConfig.for_console(DrMapConfig.GAME, console, DrMapConfig.KEYS)
	cfg.config_dir = root

	var got := cfg.apply("dr_icy")
	_check(got.size() == 3, "the course's three rules apply (%s)" % [got])
	_check(console.find_cvar("dr_gravity").get_float() == 12.0, "dr_gravity is 12 on the icy course")
	_check(console.find_cvar("dr_round_seconds").get_int() == 120, "dr_round_seconds is 120")
	_check(console.find_cvar("sv_gravity").get_int() == 800, "a cvar outside the whitelist is untouched")
	cfg.apply("dr_plain")
	_check(console.find_cvar("dr_gravity").get_float() == 20.0 and console.find_cvar("dr_autobhop").get_int() == 1, "the next course has the rules back")

	var config := DrConfig.new()
	var client := DotGameMapConfig.new()
	client.game_id = DrMapConfig.GAME
	client.config_dir = root
	client.keys = DrMapConfig.client_keys()
	client.get_fn = func(key: String) -> Variant:
		return str(config.gravity) if key == "dr_gravity" else ("1" if config.auto_bunny_hop else "0")
	client.set_fn = func(key: String, value: Variant) -> bool:
		if key == "dr_gravity":
			config.gravity = float(str(value))
		else:
			config.auto_bunny_hop = str(value) in ["1", "true"]
		return true
	var before := config.gravity
	client.apply("dr_icy")
	_check(config.gravity == 12.0 and not config.auto_bunny_hop, "the client predicts with the course's gravity and auto-hop")
	client.apply("dr_plain")
	_check(config.gravity == before and config.auto_bunny_hop == DrConfig.new().auto_bunny_hop, "the client has them back")
	_check(not DrMapConfig.client_keys().has("dr_round_seconds"), "the client takes only what it predicts with")
	_check(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://cfg/game/mg-deathrun/dot_map/map")), "the shipped starter folder exists")

	_report(CHECKS)


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
