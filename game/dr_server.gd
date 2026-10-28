extends Node

const DrConfig := preload("dr_config.gd")
const DrGame := preload("dr_game.gd")
const DrMapConfig := preload("dr_map_config.gd")

## What a [DotServer] loads as its game scene. Never a client.
## Everything a dedicated server does is in `dr_module.gd`; this exists because dot-server loads a scene, and the world must be in the tree (under [constant DrGame.SERVICE]) before the module looks for it.
## It lives in `game/` because a game is vendored by copying `game/` and only the `.tscn` files of `scenes/`; a script under `scenes/` never reaches the build.

const CHANNEL := "dr.server"

## The world this server is running. What the module will find in the registry.
var game: DrGame = null


func _ready() -> void:
	var config := DrConfig.new()

	# The family's `defaults < JSON < environment < argv` chain plus the cfg/ yml layers;
	# strict on a dedicated server, so a typo or bad value stops the boot.
	var binder := DrConfig.make_binder(config, "user://cfg/deathrun.json")
	var loaded := binder.load_layers()

	if not loaded.ok:
		DotGameConfigBinder.fail_boot(get_tree(), loaded)
		return

	game = DrGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	# Read, not chosen: the server already set it from `sv_tickrate`, and a rate of our own
	# would run the simulation at one rate inside a process ticking at another.
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)

	DotLog.info(CHANNEL, "the world is up", {
		"tick_rate": game.tick_rate,
		"courses": config.course_directory,
		"round": config.round_seconds,
	})

	# Not started here: the module builds the bridge that answers `world_rebuilt`, so a course
	# laid out now is never sent. The module starts it, on the last line of its own load.
