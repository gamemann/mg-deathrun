extends Node

const DrConfig := preload("../game/dr_config.gd")
const DrGame := preload("../game/dr_game.gd")
const DrPlayer := preload("../game/dr_player.gd")

## Where a stand-in runner is, every so often, as it runs a course with nobody at the buttons —
## and where and why it stops. The tool every route in `courses/` was tuned with.
##
## [codeblock]
## godot --headless --path . res://tools/trace_run.tscn -- --course=dr_practice --every=0.5
## [/codeblock]
##
## Not a suite: it prints and quits 0 whatever it finds. `headless_courses` is the suite.

const TICK_RATE := 64


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	var course := "dr_practice"
	var every := 0.5
	var seconds := 60.0

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--course="):
			course = arg.trim_prefix("--course=")
		elif arg.begins_with("--every="):
			every = arg.trim_prefix("--every=").to_float()
		elif arg.begins_with("--seconds="):
			seconds = arg.trim_prefix("--seconds=").to_float()

	var config := DrConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.minimum_players = 0
	config.bot_fumble_chance = 0.0
	config.keep_progress = false
	config.course_ids = PackedStringArray([course])

	var game := DrGame.new()
	game.config = config
	game.tick_rate = TICK_RATE
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame

	var bot := game.add_player(&"u900000", "Runner")
	bot.is_bot = true
	var idle := game.add_player(&"u2", "Idle")
	game.config.activator_may_repeat = true
	game.start()

	for _i in range(2):
		game.simulate(1.0 / TICK_RATE)
		await get_tree().physics_frame

	game._set_side(bot.player_id, DrGame.RUNNERS)
	game._set_side(idle.player_id, DrGame.ACTIVATORS)
	game._place_everybody()

	var said: Array = []
	game.player_died.connect(func(id: StringName, _by: StringName, why: StringName) -> void:
		said.append("%s died: %s at %s" % [id, why, (game.players[id] as DrPlayer).controller.state.position]))

	print("course %s, route of %d points" % [course, game.stage.route().size()])
	var next_print := 0.0

	for i in range(int(seconds * TICK_RATE)):
		idle.controller.apply_command(DotFpsCommand.new())
		game.simulate(1.0 / TICK_RATE)
		await get_tree().physics_frame
		var t := float(i) / TICK_RATE

		if t >= next_print:
			next_print += every
			var state := bot.controller.state
			print("%6.2f  %-28s v %-26s %s  route %d" % [t, str(state.position), str(state.velocity.snapped(Vector3.ONE * 0.01)),
				DotFpsState.Mode.keys()[state.mode], int(game._bot_route.get(bot.player_id, 0))])

		for line in said:
			print("  %s" % line)

		said.clear()

		if bot.finished:
			print("finished in %.2f s" % game.run_elapsed)
			break

		if game.round_number > 1:
			print("the round ended")
			break

	get_tree().quit(0)
