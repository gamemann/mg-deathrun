extends Node

## The client's board, figure-portrait, view-model and per-frame presentation, split out of `dr_client.gd` to keep it under the size budget. No `class_name`; the client extends this.

const DrAudio := preload("dr_audio.gd")
const DrFigure := preload("dr_figure.gd")
const DrGame := preload("dr_game.gd")
const DrHud := preload("dr_hud.gd")
const DrNetBridge := preload("net/dr_net_bridge.gd")
const DrNetCommand := preload("net/dr_net_command.gd")
const DrPlayer := preload("dr_player.gd")
const DrPlayerNet := preload("net/dr_player_net.gd")

## Seconds the drawn gun must be quiet before the server's count may overwrite it: longer than a
## shot's trip to the server and its snapshot back, so no shot still in flight is undone.
const DRAWN_SETTLE_SEC := 0.6

var game: DrGame = null

var player: DrPlayer = null

var camera: Camera3D = null

var hud: DrHud = null

## The Tab board, the menu's ([member DotGameClient.board]). See [method _dress_board].
var board: DotMenuScoreboard = null

## When this client started, for an offline board's "time".
var _started_msec: int = Time.get_ticks_msec()

## What the game sounds like. See [DrAudio].
var audio: DrAudio = null

## The weapons in this player's own hands, once they have been handed one at the end.
##
## [b]Drawn, never decided.[/b] `authority` is false and every shot that matters is the
## server's; what this rig is for is a view model that moves — a deploy, a reload, a recoil
## kick — because a weapon that appears fully formed and never animates reads as a texture
## stuck to the screen.
var weapons: ZeeWeaponRig = null

var net: DotNetManager = null

var bridge: DrNetBridge = null

var _offline: bool = true

## Which session this client is, once the server has said. -1 until then, so nothing matches
## before it does.
var _watch_id: int = -1

var _slot: int = 0

## The last whole second of the countdown a beep was played for.
var _beeped: int = -1

## The player's face for the board: their figure's head, rendered once per skin and kept, since a render per ask would be a viewport per player per frame.
## Per skin, not per player: the six figures are six atlases, and the side is a torso tint that does not reach the head.
var _portraits: Dictionary = {}

## Simulated seconds the drawn gun has gone without a trigger, a reload or a switch.
var _drawn_quiet: float = 0.0

## The Tab board: dot-menu's, with this game's columns. The platform builds it, feeds it and holds it
## on Tab (see [method _build_settings]).
##
## [b]Online it is the server's roster with this game's numbers merged in.[/b] Names, pings
## and how long each player has been on come from dot-server, which is the only thing that
## knows them for everybody; points, the face and the side are already replicated here, so
## they are joined in by id rather than sent twice. The two sides are the board's teams, the
## runners first. Offline there is no server and the board is [method board_snapshot].
func _dress_board() -> void:
	if board == null:
		return
	board.title_text = "Deathrun"
	board.columns = [
		{"key": &"avatar", "kind": DotMenuScoreboard.KIND_AVATAR, "width": 0.0},
		{"key": &"name", "title": "Player", "width": 3.0},
		{"key": &"points", "title": "Points", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]
	board.sort_by = &"points"
	board.decorate = _decorate_row
	board.prepare = _prepare_board


## This game's numbers onto a row of the server's roster, by id.
func _decorate_row(row: Dictionary) -> void:
	if game == null:
		return
	var id := DrNetBridge.player_key(int(row.get("id", 0)))
	if not game.players.has(id):
		id = StringName(str(row.get("id", "")))
	var who: DrPlayer = game.players.get(id)
	if who == null:
		return
	row["avatar"] = _face(who)
	row["points"] = who.points
	row["team"] = game.team_of(id)
	if int(row.get("ping", -1)) < 0 and who.ping_ms >= 0:
		row["ping"] = who.ping_ms
	if who == player:
		row["you"] = true


## The course in the header, and the two sides as the teams.
func _prepare_board(snap: Dictionary) -> void:
	if game == null:
		return
	snap["header"] = {"Course": str(game.course_doc.get("name", ""))}
	snap["teams"] = [
		{"id": DrGame.RUNNERS, "name": game.side_name(DrGame.RUNNERS), "color": game.side_colour(DrGame.RUNNERS)},
		{"id": DrGame.ACTIVATORS, "name": game.side_name(DrGame.ACTIVATORS), "color": game.side_colour(DrGame.ACTIVATORS)},
	]


## The board offline: every player in the local world. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var players: Array = []
	if game != null:
		for id in game.players:
			var who: DrPlayer = game.players[id]
			players.append({"id": String(id), "name": who.display_name, "seconds": _seconds_here(), "ping": -1, "bot": who.is_bot})
	return {"server": {"name": "Deathrun", "game": "offline"}, "players": players}


func _seconds_here() -> int:
	return int((Time.get_ticks_msec() - _started_msec) / 1000)



func _face(who: DrPlayer) -> Texture2D:
	return _portrait(str(who.call("_atlas")))


func _portrait(atlas: String) -> Texture2D:
	if _portraits.has(atlas):
		return _portraits[atlas]

	var view := SubViewport.new()
	view.name = "Portrait%d" % _portraits.size()
	view.size = Vector2i(64, 64)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(view)

	var figure := DrFigure.new()
	view.add_child(figure)
	figure.build(1.8, atlas, Color.WHITE)
	figure.global_position = Vector3.ZERO

	var eye := Camera3D.new()
	eye.fov = 30.0
	view.add_child(eye)
	# In front of the face (a figure looks down -Z) and a touch above it, looking back.
	# The people's heads are big: the face is about 1.35 m up a 1.8 m person.
	eye.look_at_from_position(Vector3(0.0, 1.45, -2.0), Vector3(0.0, 1.35, 0.0), Vector3.UP)
	eye.current = true

	var texture := view.get_texture()
	_portraits[atlas] = texture
	return texture


func _drive_view_model(command: DotFpsCommand) -> void:
	if weapons == null or player == null:
		return

	var weapon_command := DotWeaponCommand.new()

	if command != null:
		weapon_command.set_button(
			DotWeaponCommand.BUTTON_ATTACK, command.is_pressed(DrNetCommand.BUTTON_FIRE)
		)
		weapon_command.set_button(
			DotWeaponCommand.BUTTON_ALT, command.is_pressed(DrNetCommand.BUTTON_ALT)
		)
		weapon_command.set_button(
			DotWeaponCommand.BUTTON_RELOAD, command.is_pressed(DrNetCommand.BUTTON_RELOAD)
		)
		weapon_command.yaw = command.yaw
		weapon_command.pitch = command.pitch

	weapon_command.slot = _slot

	var _outcome := weapons.simulate_tick(weapon_command, game.round_number * 100000 + Engine.get_physics_frames())

	var busy := weapon_command.is_pressed(DotWeaponCommand.BUTTON_ATTACK) \
		or weapon_command.is_pressed(DotWeaponCommand.BUTTON_RELOAD) \
		or weapons.arsenal.is_reloading() or weapons.arsenal.is_switching()
	_drawn_quiet = 0.0 if busy else _drawn_quiet + 1.0 / float(maxi(game.tick_rate, 1))
	var _corrected := correct_drawn()



## Brings the drawn gun's magazine and reserve (what the HUD counts) to the server's once it has
## been quiet [constant DRAWN_SETTLE_SEC]: online from this player's owner-only snapshot fields,
## offline from the world's own rig. True when it changed anything.
##
## [b]The drawn gun predicts, so it can be wrong, and nothing else puts it right.[/b] A shot the
## server refused or a fresh round's refill leaves the counter on the client's own sum otherwise
## (mg-prop-hunt's `correct_drawn`, game-zombie-zone's 15 / 105).
func correct_drawn() -> bool:
	if weapons == null or weapons.arsenal == null or _drawn_quiet < DRAWN_SETTLE_SEC:
		return false

	var source := _server_count()

	if source.is_empty() or bool(source.busy):
		return false

	var arsenal := weapons.arsenal
	var held := arsenal.current()

	if held == null or int(source.slot) != arsenal.current_slot() or arsenal.is_reloading() or arsenal.is_switching():
		return false

	var changed := false

	if held.def.uses_magazine() and held.magazine != int(source.magazine):
		held.magazine = clampi(int(source.magazine), 0, held.def.magazine)
		changed = true

	if held.def.ammo_type != &"" and not held.def.infinite_reserve \
			and arsenal.ammo().count(held.def.ammo_type) != int(source.reserve):
		arsenal.ammo().set_count(held.def.ammo_type, maxi(int(source.reserve), 0))
		changed = true

	return changed


## The server's count for this player's gun: `{magazine, reserve, slot, busy}`, or empty.
func _server_count() -> Dictionary:
	if _offline:
		var world: ZeeWeaponRig = player.weapons if player != null else null
		if world == null or world == weapons or world.arsenal == null or world.arsenal.current() == null:
			return {}
		var def := world.current_def()
		return {
			"magazine": world.arsenal.current().magazine,
			"reserve": world.arsenal.ammo().count(def.ammo_type) if def.ammo_type != &"" else 0,
			"slot": world.arsenal.current_slot(),
			"busy": world.arsenal.is_reloading() or world.arsenal.is_switching(),
		}

	var mine: Variant = bridge._behaviours.get(_watch_id) if bridge != null else null
	if not (mine is DrPlayerNet):
		return {}
	var behaviour := mine as DrPlayerNet
	return {
		"magazine": behaviour.net_magazine, "reserve": behaviour.net_reserve, "slot": behaviour.net_slot,
		"busy": behaviour.net_reloading or behaviour.net_switching,
	}


## Poses the course for this FRAME, between two ticks.
##
## [b]A frame, not a tick: the obstacles are drawn at the time the frame shows.[/b] The arms
## and the movers are a function of time, so the client can draw them at the exact fraction
## through a tick this frame is — which no snapshot could give it. The local player's own
## prediction poses the course back at its tick before every simulated tick (see
## [DrController]), so drawing it between them never moves what a tick is swept against.
func _pose_stage() -> void:
	if game == null or game.stage == null or game.stage.doc.is_empty():
		return

	var tick := float(game.current_tick())
	var alpha := Engine.get_physics_interpolation_fraction()

	if net != null and net.is_running():
		tick = float(net.clock.tick)
		# At the alpha your own player is drawn at (see `present_frame`), so a clock slip
		# moves the course and the player on it together; at the engine's fraction a rider
		# on a mover slid a tick against it for a moment after each. By name, for an older
		# shell's dot-net.
		if net.clock.has_method(&"render_alpha"):
			alpha = float(net.clock.call(&"render_alpha"))

	game.stage.pose_at_time((tick + alpha) / float(maxi(game.tick_rate, 1)))


## What a frame on a course adds: the countdown's beeps.
func _present_course(_delta: float) -> void:
	if game == null:
		return

	if game.phase == DrGame.Phase.COUNTDOWN:
		var second := int(ceilf(game.seconds_left()))

		if second != _beeped and second <= 3 and second > 0:
			_beeped = second

			if audio != null:
				var _heard := audio.on_countdown()

			if hud != null:
				hud.shout("%d" % second, 0.9)
	else:
		_beeped = -1


func _present_effects(delta: float) -> void:
	# The ears are wherever the eyes are, which for somebody who is out is the spectator
	# camera — so a player watching a team-mate hears what that team-mate hears.
	if audio != null:
		audio.listen_from(camera.global_position)
		audio.keep_walkers(game.players.values())

	if game.effects != null:
		game.effects.viewer_position = camera.global_position
		game.effects.advance(delta)


# Watching, once out


## Everything a frame draws that a tick does not, in this order: the netcode's
## interpolation, then every player's body, then every beacon. Returns how many bodies are
## shown. Static so the net suite drives exactly this and not a copy of it.
##
## [b]The interpolation was never called in this game, and a comment here said it was.[/b]
## `present_beacons`, which this replaces, read a remote player's node on the grounds that
## "everybody else's node is written by the interpolator once a frame already" — and nothing
## anywhere called `DotNetManager.interpolate_frame`, so nothing wrote it. The
## `_net_interpolated` hooks on `DrPlayerNet` and `DrPropNet` were written, documented and
## reached by nothing, and every remote player and prop moved only when a snapshot landed —
## mg-smash-copter's finding, the render-jitter class. The other half was that a remote player had no body to move
## ([DrFigure]).
##
## [param first_person] is whether [param own]'s camera is behind their eyes, which is what
## hides their own body. [param alpha] is the fraction through the current tick; -1 derives it
## from the engine, which is what a real frame wants. A suite passes it, because a suite's
## frames are not an engine's.
static func present_frame(
	p_net: DotNetManager,
	p_game: DrGame,
	own: DrPlayer,
	first_person: bool,
	delta: float,
	alpha: float = -1.0,
	watched: DrPlayer = null
) -> int:
	var networked := p_net != null and p_net.is_running()

	if networked:
		p_net.interpolate_frame(alpha)

	# Your own player is drawn at the clock's render alpha, not the engine's fraction: the
	# clock stretches and shrinks its ticks while it settles on the server, so a physics frame
	# now and then runs no tick or two, and drawn at the engine's fraction the eye stood still
	# on one frame and moved double on the next. `DotFpsController.render_state` reads it from
	# `render_clock` (dot-player-controller); by name both ways, so a shell older than either
	# draws as before. Null offline, where every physics frame is one tick.
	if own != null and own.controller != null:
		own.controller.set(&"render_clock", p_net.clock if networked else null)

	if p_game == null:
		return 0

	var shown := 0

	for key: StringName in p_game.players:
		var body: DrPlayer = p_game.players[key]

		if body == null or not is_instance_valid(body) or not body.is_inside_tree():
			continue

		var mine := body == own
		var at := drawn_position(body, networked and not mine)
		var colour := p_game.side_colour(p_game.team_of(key))

		# A runner does not see the activators behind the walls, except in the showdown,
		# where they are fighting. Drawn as though it were the camera's own body: not at all.
		var unseen := (
			not p_game.config.activators_seen and own != null and not mine
			and p_game.team_of(own.player_id) == DrGame.RUNNERS
			and p_game.team_of(key) == DrGame.ACTIVATORS
			and p_game.phase != DrGame.Phase.SHOWDOWN
		)

		# And whoever a spectator is looking out of: a camera inside somebody's head draws the
		# inside of their head.
		if body.present_body((mine and first_person) or body == watched or unseen, at, colour):
			shown += 1

		# Every player's beacon, this client's own included — somebody who has been beaconed
		# sees their ring and hears their ping too. After the interpolation, so a ring is
		# placed where this frame draws them rather than where the last one did.
		var _pinged := body.present_beacon(delta, at, mine)

	return shown


## Where this frame draws [param body].
##
## [b]Two sources, and which one is not a detail.[/b] A player somebody else simulates — any
## [param remote] player on a connected client — is placed by the interpolator, which writes
## their node once a frame; their controller never ticks here, so its render state is a blend
## of two ticks that never happened. A player THIS process simulates — the local player, and
## every offline stand-in — has a node that moves once a tick, and `render_state` is the
## blend between the last two, which is what the camera is drawn from too.
static func drawn_position(body: DrPlayer, remote: bool) -> Vector3:
	if remote or body.controller == null:
		return body.global_position

	return body.controller.render_state().position
