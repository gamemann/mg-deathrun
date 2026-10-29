extends DotGameCheckSuite

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

## Base of [code]headless_run.gd[/code]: the shared constants, state and helpers, and the
## client-side sections, split out to keep each file under the size budget.

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _sections_entered := 0
var _sections_finished := 0

var _worlds: Array[DrGame] = []


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
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName, _weapon: StringName) -> void:
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
		int(asks.get("dot_ui", 0)) >= 13 and FileAccess.file_exists("res://" + DotAddonApi.FLOOR_FILE),
		"the pack asks a shell for dot-ui level 13, the weapon icons (requires.floor.json)",
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
	# Your own view is first person, so no figure is drawn yet: give it one as the third-person view does.
	var DrFigureScript: GDScript = load("res://game/dr_figure.gd")
	me.figure = DrFigureScript.new()
	me.figure.person = DotHumanoidFigure.new()
	me.figure.add_child(me.figure.person)
	add_child(me.figure)
	var action_fig: Object = client.call(&"_avatar_figure", 0)
	_check(action_fig != null and action_fig == me.figure.person and action_fig.has_method(&"skeleton"),
		"an avatar action and a wearable go on the runner's own person, which can hang a wearable",
		"%s %s %s" % [action_fig, me.figure, me.figure.person if me.figure != null else null])
	me.figure.pose(me.global_position, 0.0, 3.0)
	_check(int(me.figure.person.get("_posed_frame")) == Engine.get_process_frames(),
		"a posed figure animates by game time, not the wall clock")
	me.health.alive = false
	_check(client.call(&"_avatar_figure", 0) == null, "a dead runner has no figure for an action")
	me.health.alive = true
	me.figure.free()
	me.figure = null
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
	_drawn_gun_hud_checks(client, drawn)
	var hud: Node = client.get("hud")

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


## The HUD half of the drawn-gun section: counter, weapon sprite and its placement.
func _drawn_gun_hud_checks(client: Node, drawn: ZeeWeaponRig) -> void:
	var hud: Node = client.get("hud")
	hud.call("_process", 0.0)
	var counter: DotAmmoCounter = hud.get("ammo")
	var def := drawn.current_def() if drawn != null else null
	var expected := "%d | %d" % [drawn.arsenal.current().magazine, drawn.arsenal.ammo().count(def.ammo_type)] if def != null else "?"
	_check(counter != null and counter.visible and def != null and counter.weapon_name == def.display_name
		and counter.count_text() == expected,
		"the HUD has DotAmmoCounter, counting the drawn gun",
		"%s %s, want %s" % [counter.weapon_name if counter else "-", counter.count_text() if counter else "-", expected])
	var icon_script: Script = load("res://game/dr_weapon_icons.gd")
	var icons: DotWeaponIconStyle = icon_script.get("shared")
	var icon_rect: TextureRect = hud.get("weapon_icon")
	var unmapped := PackedStringArray()
	for weapon in icon_script.get("TAGS"):
		if not icons.icon_set().has_icon(weapon):
			unmapped.append(String(weapon))
	_check(unmapped.is_empty() and icon_rect != null and icon_rect.visible and icon_rect.texture != null and icon_rect.texture == icons.texture(def.id),
		"the HUD draws the held gun's sprite over the counter, and every mapped weapon has one", ", ".join(unmapped))
	var _silhouette := icons.set_style(&"silhouette")
	hud.call("_process", 0.0)
	_check(icon_rect != null and not icon_rect.visible, "cl_weapon_icons silhouette hides the sprite")
	var _pixel := icons.set_style(&"pixel")
	hud.call("_process", 0.0)
	_check(icon_rect != null and icon_rect.visible and icon_rect.get_global_rect().end.y <= counter.get_global_rect().position.y + 4.0,
		"the sprite sits above the ammunition plate, not on it")
	_check(counter.anchor_left == 1.0 and counter.anchor_top == 1.0 and counter.offset_top >= -180.0
		and counter.offset_bottom <= -100.0,
		"it sits bottom right, above the field line and clear of the chat and the health plate")


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
