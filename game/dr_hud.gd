extends CanvasLayer

const DrGame := preload("dr_game.gd")
const DrPlayer := preload("dr_player.gd")

## The clock, which side you are on, how many of each are left, and — at the buttons — which
## traps you still have and which one you are looking at.
##
## [b]The activator's list of traps is the number they cannot read off the world.[/b] A
## button's cap goes red when its trap is spent, but the activator is watching the runners and
## not the caps; a list down the side says what is left without a turn of the head, and the
## line in the middle says which button E would press right now, before it is pressed.
##
## [b]Health only at the end.[/b] Nothing on a course hurts a little — a trap is a death — so a
## health number there would be a number that never moves.

# No `const CHANNEL`. This draws numbers from state somebody else owns and has nothing an
# operator would act on; a channel declared and never used is a file that meant to say
# something and does not.

var game: DrGame = null
var player: DrPlayer = null

var _clock: Label = null
var _phase: Label = null
var _role: Label = null
var _health: Label = null
var _field: Label = null
var _course: Label = null
var _shout: Label = null
var _traps: Label = null
var _prompt: Label = null

## What a player who is out is looking at, and the keys that change it. Empty while playing.
var watching_label: Label = null
var _bar_back: ColorRect = null
var _bar_fill: ColorRect = null
var _root: Control = null

## Seconds left of the big shouted line in the middle of the screen.
var _shout_for: float = 0.0

## An administrator's `blind`, over the world and under the HUD's numbers. See mg-wipeout: a
## blind takes the game away, not the player's bearings, and black rather than white.
var blind_overlay: ColorRect = null

const BLIND_FADE_SEC := 0.25

const BLIND_COLOUR := Color(0.01, 0.01, 0.015)

const READY_COLOUR := Color(0.55, 0.95, 0.55)
const SPENT_COLOUR := Color(0.70, 0.40, 0.38)


func bind(p_game: DrGame, p_player: DrPlayer) -> void:
	game = p_game
	player = p_player

	if _root == null:
		_build()


func _build() -> void:
	# A full-rect Control between the CanvasLayer and the labels: a CanvasLayer is not a
	# Control and does not lay its children out, so anchors on a Label parented straight to one
	# resolve against nothing. game-buses-from-hell's first render.
	_root = Control.new()
	_root.name = "Screen"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	blind_overlay = ColorRect.new()
	blind_overlay.name = "Blind"
	blind_overlay.color = BLIND_COLOUR
	blind_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blind_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blind_overlay.modulate.a = 0.0
	blind_overlay.visible = false
	_root.add_child(blind_overlay)

	var size := 22

	_clock = _label(size + 14)
	_clock.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_clock.offset_top = 16.0
	_clock.offset_bottom = 72.0
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_phase = _label(size)
	_phase.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_phase.offset_top = 74.0
	_phase.offset_bottom = 108.0
	_phase.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_course = _label(size - 4)
	_course.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_course.offset_top = 110.0
	_course.offset_bottom = 140.0
	_course.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_course.add_theme_color_override("font_color", Color(0.80, 0.88, 0.98))

	# Top left: which side you are, in that side's colour. The one fact about a round that
	# changes every round and that everything else on the screen depends on.
	_role = _label(size + 4)
	_role.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_role.offset_left = 30.0
	_role.offset_top = 22.0
	_role.offset_right = 420.0
	_role.offset_bottom = 60.0

	_shout = _label(size + 20)
	_shout.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_shout.offset_top = 190.0
	_shout.offset_bottom = 260.0
	_shout.offset_left = -560.0
	_shout.offset_right = 560.0
	_shout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shout.add_theme_color_override("font_color", Color(0.99, 0.86, 0.40))

	# Under the crosshair, small: what E would do now. Close to where the eye already is,
	# because an activator presses while watching the trap, not the corner of the screen.
	_prompt = _label(size)
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_prompt.offset_left = -300.0
	_prompt.offset_right = 300.0
	_prompt.offset_top = 26.0
	_prompt.offset_bottom = 60.0
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# Down the right: the activator's traps. Above the field count, which is bottom right.
	_traps = _label(size - 4)
	_traps.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	_traps.offset_left = -330.0
	_traps.offset_right = -30.0
	_traps.offset_top = 150.0
	_traps.offset_bottom = -110.0
	_traps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	# Above the chat box, because the chat box also draws itself bottom-left: mg-wipeout's
	# first render had the health number and the first line of chat in the same forty pixels.
	_health = _label(size + 16)
	_health.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_health.offset_left = 30.0
	_health.offset_right = 300.0
	_health.offset_top = -210.0
	_health.offset_bottom = -150.0

	_field = _label(size)
	_field.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_field.offset_left = -460.0
	_field.offset_right = -30.0
	_field.offset_top = -80.0
	_field.offset_bottom = -26.0
	_field.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	watching_label = _label(size)
	watching_label.name = "Watching"
	watching_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	watching_label.offset_left = -520.0
	watching_label.offset_right = 520.0
	watching_label.offset_top = -140.0
	watching_label.offset_bottom = -104.0
	watching_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	watching_label.add_theme_color_override("font_color", Color(0.80, 0.90, 1.0))

	_build_bar()

	var dot := ColorRect.new()
	dot.name = "Crosshair"
	dot.color = Color(1.0, 1.0, 1.0, 0.75)
	dot.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	dot.offset_left = -3.0
	dot.offset_top = -3.0
	dot.offset_right = 3.0
	dot.offset_bottom = 3.0
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dot)


## The bar along the bottom: how much of the course is behind a runner.
func _build_bar() -> void:
	_bar_back = ColorRect.new()
	_bar_back.name = "BarBack"
	_bar_back.color = Color(0.0, 0.0, 0.0, 0.42)
	_bar_back.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_bar_back.offset_left = -150.0
	_bar_back.offset_right = 150.0
	_bar_back.offset_top = -46.0
	_bar_back.offset_bottom = -30.0
	_bar_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_bar_back)

	_bar_fill = ColorRect.new()
	_bar_fill.name = "BarFill"
	_bar_fill.color = Color(0.40, 0.72, 0.95, 0.9)
	_bar_fill.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_bar_fill.offset_left = -150.0
	_bar_fill.offset_right = -150.0
	_bar_fill.offset_top = -46.0
	_bar_fill.offset_bottom = -30.0
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_bar_fill)


func _label(size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color(1, 1, 1))
	# An outline rather than a panel behind it: readable over ice, stone and sky alike.
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 6)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(label)
	return label


## The spectator line, or an empty string to take it away. See [DrSpectate.line_for].
func set_watching(text: String) -> void:
	if watching_label != null:
		watching_label.text = text


## One line in the middle of the screen, for a few seconds.
func shout(text: String, seconds: float = 3.5) -> void:
	if _shout == null:
		return

	_shout.text = text
	_shout_for = seconds


func _process(delta: float) -> void:
	present_blind(delta)

	if game == null or game.config == null or _root == null:
		return

	var left := game.seconds_left()
	_clock.text = "%d:%02d" % [int(left) / 60, int(left) % 60]
	_phase.text = _phase_line()
	_course.text = str((game.stage.doc if game.stage != null else {}).get("name", ""))

	var side := game.team_of(player.player_id) if player != null else 0
	var in_round := game.phase != DrGame.Phase.IDLE
	_role.text = game.side_name(side).trim_suffix("s").to_upper() if in_round and side != 0 else ""
	_role.add_theme_color_override("font_color", game.side_colour(side).lightened(0.25))

	if player != null and player.health != null and player.at_end and player.is_alive():
		_health.text = "%d" % int(round(player.health.health))
		var hurt := player.health.health <= player.health.max_health * 0.25
		_health.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3) if hurt else Color(1, 1, 1))
	else:
		_health.text = ""

	_field.text = "%d running · %d at the buttons" % [
		game.alive_on(DrGame.RUNNERS), game.alive_on(DrGame.ACTIVATORS)]

	_draw_traps(side)
	_draw_bar(side)

	if _shout_for > 0.0:
		_shout_for -= delta

		if _shout_for <= 0.0:
			_shout.text = ""


func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var want := 1.0 if is_blind() else 0.0
	blind_overlay.modulate.a = move_toward(
		blind_overlay.modulate.a, want, maxf(delta, 0.0) / BLIND_FADE_SEC
	)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0


func is_blind() -> bool:
	return player != null and is_instance_valid(player) and player.blinded


func _phase_line() -> String:
	if not game.sides_are_playable():
		return "waiting for players"

	var activator := player != null and game.team_of(player.player_id) == DrGame.ACTIVATORS

	match game.phase:
		DrGame.Phase.COUNTDOWN:
			return "find your first button" if activator else "the gate drops soon"
		DrGame.Phase.RUN:
			if player != null and player.watching:
				return "you joined mid-round — watching"
			if activator:
				return "press E at a button while they are in its trap"
			return "%.1f s" % game.run_elapsed
		DrGame.Phase.SHOWDOWN:
			if player != null and player.at_end:
				return "at the end — finish it"
			if activator:
				return "called to the end"
			return "somebody made it — run"
		_:
			return "between rounds"


## The activator's traps, ready or spent, and the button in front of them.
func _draw_traps(side: int) -> void:
	_prompt.text = ""
	_traps.text = ""

	if game.stage == null or side != DrGame.ACTIVATORS or player == null or player.at_end \
			or not player.is_alive() or is_blind():
		return

	var tick := game.current_tick()

	if game.phase != DrGame.Phase.RUN and game.phase != DrGame.Phase.COUNTDOWN:
		return

	var lines := PackedStringArray()

	for index in range(game.stage.trap_count()):
		var ready := game.stage.trap_ready(index, tick)
		lines.append("%s  %s" % [game.stage.trap_name(index), "●" if ready else "○"])

	_traps.text = "\n".join(lines)

	var looking := game.stage.button_for(player.eye_position(), player.aim_direction(),
		game.config.button_reach, game.config.button_cone)

	if looking < 0:
		return

	if game.stage.trap_ready(looking, tick):
		_prompt.text = "E — %s" % game.stage.trap_name(looking)
		_prompt.add_theme_color_override("font_color", READY_COLOUR)
	else:
		_prompt.text = "%s — spent" % game.stage.trap_name(looking)
		_prompt.add_theme_color_override("font_color", SPENT_COLOUR)


## How far along the course a runner is: from the start line to the finish, along the line
## between them. Hidden for an activator, at the end, and behind an admin's blind.
func _draw_bar(side: int) -> void:
	if _bar_fill == null or _bar_back == null:
		return

	var shown := player != null and side == DrGame.RUNNERS and game.stage != null \
		and not game.stage.doc.is_empty() and game.phase != DrGame.Phase.IDLE \
		and player.is_alive() and not is_blind()

	_bar_back.visible = shown
	_bar_fill.visible = shown

	if not shown:
		return

	var from: Vector3 = (game.stage.doc["start"] as Dictionary)["at"]
	var to: Vector3 = (game.stage.doc["finish"] as Dictionary)["at"]
	var line := to - from
	var along := (player.global_position - from).dot(line) / maxf(line.length_squared(), 0.01)
	var fraction := 1.0 if player.finished else clampf(along, 0.0, 1.0)
	_bar_fill.offset_right = -150.0 + 300.0 * fraction
	_bar_fill.color = Color(0.98, 0.80, 0.30, 0.95) if player.finished \
		else Color(0.40, 0.72, 0.95, 0.9)
