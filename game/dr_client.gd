extends "dr_client_base.gd"

const DrBindings := preload("dr_bindings.gd")
const DrWeaponIcons := preload("dr_weapon_icons.gd")
const DrSettings := preload("dr_settings.gd")
const DrServices := preload("dr_services.gd")

const DrConfig := preload("dr_config.gd")
const DrMapConfig := preload("dr_map_config.gd")
const DrPaths := preload("dr_paths.gd")
const DrKillcam := preload("dr_killcam.gd")

## One local player, a camera and a HUD over an [DrGame] — offline, or against a server.
##
## [b]One client for both, and the offline half is not a demo mode.[/b] It is the same world
## class with `authoritative` true and nothing else different: the same courses, the same
## obstacles, the same rules. What changes is where the answers come from, and the whole of
## that difference is [DrNetBridge]. A separate single-player build would be a second game to
## keep in step, and this family has watched two copies of one thing drift more than once.
##
## [b]Which half runs is decided by whether there is a link in the registry.[/b] A dot-server
## client publishes a [DotClientLink] under `dot_client_link` before the game scene loads; no
## link means nobody connected us to anything, and the honest answer to that is a playable
## course rather than an error. `--offline` forces it.
##
## [b]First person and third, and the motor does not know which.[/b] The camera is
## presentation: the simulation is first-person, command-driven and predictable in both, and
## what changes is where the camera sits. That is the line dot-player-controller draws
## between its motor and its view, drawn again here — and on a course the third person view
## is the one that shows where your feet are against a trapdoor's edge.

const CHANNEL := "dr.client"

## Where a dot-server client link publishes itself.
const LINK_SERVICE := &"dot_client_link"

## Where the camera sits behind the player in third person, in metres.
const CHASE_BACK := 4.6
const CHASE_UP := 2.1

## The use key's default, for a HUD with no table to ask ([DrBindings] is what the client
## reads). The HUD names the key as bound ([member DrHud.use_action]).
const USE_KEY := KEY_E

@export var config_file: String = "user://cfg/deathrun.json"

## Play alone even when a link is available. `--offline`.
@export var force_offline: bool = false

## How many stand-ins an offline round gets: somebody at the buttons when you are running,
## and somebody running when you are at them.
@export_range(0, 12, 1) var offline_bots: int = 3

## Which view the camera starts in.
@export var third_person: bool = false

## Keeps the screen covered, and the local body and the input still, until the level, the
## player and the camera are all in. See [member DotGameClient.gate].
var gate: DotLoadGate = null

## dot-game's client platform: the cover, settings and menu, console, HUD theme, Tab, M, the
## pointer and the input block. See [DotGameClient].
var platform: DotGameClient = null
var chat: DotGameChatClient = null

## The player's own settings and the screen Escape opens. See [DrSettings].
var settings: DrSettings = null

## The player's console. See [method DotConsoleKit.build].
var console: DotConsoleController = null

var view_model: ZeeViewModel = null

## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var workbench_remote: DotGameWorkbenchRemoteClient = null
## The tuning panel's host: F9 solo, the admin's remote panel on a server that allows it.
var workbench: DotGameWorkbench = null
var link: Node = null
## Records every frame and replays the round's last moment ([DrKillcam]); then the reveal.
var killcam: DrKillcam = null
var winner_reveal: DotWinnerReveal = null
## The server's `mp_killcam_time`; -1 until it has said, so the config's number stands.
var _killcam_sec: float = -1.0
var _round_ending: bool = false
var _round_end_number: int = 0
var _round_end_why: String = ""
var _round_board_open: bool = false
var _hud_was_visible: bool = true

var _sampler: DotFpsSampler = null

## The spectator's free camera while roaming, and the mouse motion not yet turned into a look.
var _free_cam: DotSpectatorFreeCam = null
var _roam_look: Vector2 = Vector2.ZERO

## The last [member DrPlayer.warps] this client re-aimed its mouse for.
var _seen_warps: int = 0

## The camera rig, in third person. Null in first.
var _arm: DotCameraBoom = null
var _fade: DotCameraFade = null

## How far above the player's feet the camera, or in third person the arm, is hung.
var _rig_height: float = 0.0

## Held buttons, read once a tick rather than sampled from an event queue.
var _firing: bool = false
var _alt: bool = false
var _reloading: bool = false
## The use key, held. Presses the button in front of an activator; see `DrGame._advance_buttons`.
var _use: bool = false


func _ready() -> void:
	# First, before anything can be drawn: the course and the player arrive after this node is
	# in the tree. The platform puts the loading cover up, held until the player exists and the
	# camera is current, and finds the link.
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = force_offline
	platform.spawned_fn = func() -> bool: return player != null
	platform.scoreboard_action = DrBindings.SCOREBOARD
	add_child(platform)
	gate = platform.gate

	# The art is this game's copy: `ZeeWeaponArtTable` names `res://assets/…`, which a delivered pack lacks.
	ZeeModelCache.set_asset_root(DrPaths.root())

	var config := DrConfig.new()

	# The family's config chain on the client too, or a flag would work on a server and not offline.
	var binder := DrConfig.make_binder(config, config_file)
	var loaded := binder.load_layers()

	if not loaded.ok:
		DotLog.warn(CHANNEL, "falling back to defaults", {"why": loaded.error.message})

	link = platform.link as Node
	_offline = platform.offline

	game = DrGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	game.authoritative = _offline
	# A connected client's world is not what a module looks up; registering it would fight a server in the same process.
	game.register_service = _offline
	game.tick_rate = int(
		ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 64)
	)
	# The sky, the sun and the void: drawn here, never on a server.
	game.draw_world = true
	# Before the world is added: a server-less world lays its first course out in its own _ready.
	_hold_for_courses()
	add_child(game)
	_build_ragdolls()

	# Here and not on the player: a connected client's player arrives in a JOIN, frames after the keyboard.
	_sampler = DotFpsSampler.new(DrPlayer.tunables_for(config))
	DrPlayer.register_actions(_sampler)

	_build_hud()
	_build_chat()
	_build_audio()
	_build_settings()
	_build_killcam()

	if _offline:
		_start_offline()
	else:
		# In `_ready`, inside `DotClientLink._load_scene`: the netcode is up before the server is told we loaded.
		var netted := _build_netcode()
		DotLog.result(CHANNEL, "the netcode", netted)
		if netted.ok:
			_start_remote_workbench()


## The load gate is [member DotGameClient.gate].
##
## [b]Covered also means the round does not run.[/b] Offline the world ticks itself, so the
## countdown, the stand-in activators' buttons, the traps' deaths and the round clock would all
## have run in front of a picture; `DrGame.hold_clock` stops all of them and leaves only the
## bodies, which settle onto the floor under the cover with their input off. Connected, the
## server owns the round and a runner's death is its decision; what is left to hold is this
## end's sampling and keys, which wait on [method _covered].

## A course is built: held from the moment the old one starts to go, released once the new one
## stands. [signal DrGame.world_clearing] and [signal DrGame.world_rebuilt] fire for the first
## course, the next round's and one a server sent.
func _hold_for_courses() -> void:
	game.world_clearing.connect(func() -> void: gate.hold(&"map", "Loading the course"))
	game.world_rebuilt.connect(func() -> void: gate.release(&"map"))
	game.hold_clock = _covered


## True while the load gate covers the screen: no input, no prediction sampling, no round clock.
func _covered() -> bool:
	return gate != null and not gate.is_open()


# --- Dead bodies -----------------------------------------------------------

## Where the dead lie: dot-player-char's ragdolls under the game's (the server's) rules.
var ragdolls: DotPlayerRagdolls = null


func _build_ragdolls() -> void:
	ragdolls = DotPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = game.ragdoll_rules
	ragdolls.sound_fn = _ragdoll_sound
	add_child(ragdolls)


func _ragdoll_sound(id: StringName, at: Vector3, volume: float) -> void:
	if audio != null:
		var _played := audio.on_body(id, at, volume)


## [param who]'s body falls the way the server picked ([member DrPlayer.death]), copied from the
## figure this client draws; the figure itself stays hidden while they are dead
## ([method DrPlayer.present_body]). Nobody's figure, nothing: a first-person player who never
## had one drawn here.
func _fall(who: DrPlayer) -> void:
	if who == null or ragdolls == null or who.figure == null or not who.figure.is_inside_tree():
		return
	if game.physics != null:
		# The course is on `world`; a body lands on it and on nothing else.
		game.ragdoll_rules.collision_mask = game.physics.layer_mask(&"world")
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	var _body := ragdolls.spawn(who.figure, who.death if who.death != null else DotPlayerDeath.new(), velocity)


# --- Offline ---------------------------------------------------------------

## The figure an avatar action plays on: that peer's player, or the local one offline; none once they are dead (the body is a ragdoll and the figure hidden).
func _avatar_figure(peer_id: int) -> Object:
	var who: DrPlayer = null
	if bridge != null and peer_id != 0:
		who = game.players.get(DrNetBridge.player_key(bridge.player_for_peer(peer_id)), null)
	if who == null and player != null and (net == null or peer_id == net.local_peer_id):
		who = player
	return who.figure.person if who != null and who.figure != null and who.is_alive() else null


func _exit_tree() -> void:
	# A static outlives the game: the next one the shell loads must not look for its art here.
	ZeeModelCache.set_asset_root("res://")


func _start_offline() -> void:
	# Stand-ins, named as a server names them. Which side anybody is on is the round's draw,
	# the same as on a server.
	var taken: Array = ["You"]
	for i in range(offline_bots):
		var bot_name := DotBotNames.pick(taken, i, DrGame.BOT_NAMES)
		taken.append(bot_name)
		var bot := game.add_player(StringName("u%d" % (DrNetBridge.FIRST_BOT_SESSION + i)), bot_name)
		bot.is_bot = true

	_adopt(game.add_player(&"local", "You", 0, true))
	_hear_the_world()

	# How well they play: `bot_difficulty` and every `bot_*` at the console, or
	# `-- --bot_difficulty <preset>` at launch; the settings a server binds as cvars.
	var skill := DotBotSettings.of(game)
	var args := OS.get_cmdline_user_args()
	var at := args.find("--bot_difficulty")
	if at >= 0 and at + 1 < args.size():
		DotLog.result(CHANNEL, "bot difficulty from the command line", skill.set_difficulty(args[at + 1]))
	if console != null:
		var local := DotConsoleLocal.new()
		console.add_source(local)
		var _bound := skill.bind_console(local)
		var _icons := DrWeaponIcons.shared.bind_console(local)

	# Offline the world counts for the player at this keyboard, so it is the world that says
	# what they earned. Connected, the same line arrives as a notice from the server.
	game.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		if player != null and id == player.player_id and chat != null:
			chat.say_locally("Achievement: %s (+%d)" % [title, points], Color(0.98, 0.84, 0.40))
	)
	# Offline the world is the authority, so its own word on a hit is the confirmation.
	game.hit_landed.connect(func(id: StringName, point: Vector3, killed: bool, headshot: bool) -> void:
		if id == &"local":
			_on_hit(point, killed, headshot))
	game.start()

	# No bridge: the box still opens and still echoes, because a chat box that does nothing
	# at all reads as broken rather than as absent.
	DotLog.result(CHANNEL, "chat, offline", chat.attach(null))


## Follows the server's replicated cvars through the link, so this end traces, draws and flies under the same rules.
func _follow_cvars() -> void:
	# The server's `mp_teammate_passthrough`, and every change to it, through the link: this
	# end traces its own shots for tracers and impacts, and on its default 1 against a server
	# on 0 or 2 they ended in (or went through) a team-mate where the server's did the
	# opposite. An older shell's link cannot say, and the manager keeps its default.
	if game.combat != null and link != null:
		var _following := game.combat.follow_cvars(link)
	# The server's sv_ragdoll* set: this end draws the bodies.
	if link != null:
		var _bodies := game.ragdoll_rules.follow_cvars(link)
		# And sv_toys*: a client hides the toys a server took away.
		var _toys := game.toy_rules.follow_cvars(link)
		# The server's mp_forceview and mp_solidplayers: this end places its own camera and
		# predicts its own player.
		var _view := game.view_rules.follow_cvars(link)
		var _solid := game.body_rules.follow_cvars(link)
		var _ambient := game.ambient_rules.follow_cvars(link)
		if link.has_method(&"replicated_cvar"):
			_on_killcam_cvar("mp_killcam_time", String(link.call(&"replicated_cvar", "mp_killcam_time", "")))
			if link.has_signal(&"replicated_cvar_changed"):
				link.connect(&"replicated_cvar_changed", _on_killcam_cvar)
		# And mp_forcecamera / mp_freeroam*: this end flies the spectator's free camera.
		var _spectate := game.spectate_rules.follow_cvars(link)


# --- Connected -------------------------------------------------------------

func _build_netcode() -> DotResult:
	_follow_cvars()

	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	# [b]Empty, and it is not tidiness.[/b] The manager reads a JSON file by default, so a
	# client with a stale `user://dot_net.json` runs at a tick rate the game did not choose
	# and nothing says so.
	net.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = game.tick_rate
	config.snapshot_rate = DrGame.NET_SNAPSHOT_RATE
	config.enable_prediction = true
	# Off on a client: rewinding is what a server does to resolve somebody's shot, and a
	# client resolves nobody's.
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	# From the game, not written here. Two files holding this number is how another game in
	# this family ended up decoding positions against a range the server never used.
	config.world_extent = DrGame.NET_WORLD_EXTENT
	net.config = config
	add_child(net)

	var started := net.setup()

	if not started.ok:
		return started

	bridge = DrNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	# Under the link, and NAMED the same as the server's — the name is the routing.
	bridge.open_link(link)
	# Before the seal and in the server's order (after the bridge), or the actions stay local.
	DotLog.result(CHANNEL, "avatar action message", DotGameAvatarActionMessage.register(net))
	# The server's order again (after the avatar frame): the remote workbench's frame.
	workbench_remote = DotGameWorkbenchRemoteClient.attach(net)
	net.messages.seal()

	bridge.hello_received.connect(_on_hello)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.phase_received.connect(_on_phase)
	bridge.round_changed.connect(_on_round)
	bridge.death_received.connect(_on_death)
	bridge.armed_received.connect(_on_armed)
	bridge.hit_received.connect(_on_hit)
	bridge.stage_received.connect(_on_stage)
	bridge.finished_received.connect(_on_finished)
	bridge.trap_received.connect(_on_trap)
	_hear_the_wire()
	# [b]Where a refusal is drawn.[/b] The server answers a gagged or too-fast line with a
	# notice to that one player, and a notice nothing draws is the server explaining itself
	# to nobody — which is indistinguishable from chat being broken.
	bridge.notice_received.connect(func(text: String) -> void:
		if chat != null:
			chat.notice(text)
	)

	# The one thing that writes an RTT sample. dot-net never touches a transport, so nothing
	# in it can; without this the clock's input lead omits the flight time and past about
	# thirty milliseconds every command arrives after its tick and is discarded as late.
	if link != null and link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	DotLog.result(CHANNEL, "chat and voice", chat.attach(bridge))

	# READY, and not one byte before the scene exists. dot-server's signon finishes and THEN
	# the client builds this; anything the server sent in between landed on a node that did
	# not exist and was lost, one "Node not found" per call.
	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	return net.start()


func _say_ready() -> void:
	if workbench_remote != null:
		workbench_remote.ask()
	if bridge != null:
		bridge.ask_ready()


func _on_hello(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.players.get(DrNetBridge.player_key(session_id)))


## A player arrived or changed. The one we are waiting for might be us.
##
## [b]Connected before anything can create a player rather than only checked on HELLO.[/b]
## HELLO and JOIN are both reliable and ordered, so HELLO does arrive first — but "the
## ordering happens to save us" is exactly the reasoning that put this bug in another game
## here, and a check that costs nothing is cheaper than depending on it.
func _on_roster_changed(session_id: int) -> void:
	if session_id == _watch_id and player == null:
		_adopt(game.players.get(DrNetBridge.player_key(session_id)))


func _adopt(candidate: DrPlayer) -> void:
	if candidate == null or player == candidate:
		return

	player = candidate
	if gate != null:
		gate.freeze(player)
	_build_camera()
	if platform != null:
		_suspend_input(platform.is_input_blocked())

	# Offline the world samples this player's movement itself, so the buttons go onto that
	# sample (`command_stamp`); stamping `current_command` below only reaches the drawn gun.
	if _offline:
		player.command_stamp = _stamp

	if settings != null:
		settings.bind_camera(camera)
		# Offline the player samples for themselves, from their controller's own tunables.
		if player.sampler != null:
			settings.bind_look(player.sampler.tunables)

	if hud != null:
		hud.bind(game, player)


# --- What the server says --------------------------------------------------

func _on_phase(phase: int) -> void:
	_hear_phase(phase)

	match phase:
		DrGame.Phase.COUNTDOWN:
			_disarm_locally()

			if is_activator():
				hud.shout("YOU ARE THE ACTIVATOR — %s presses a button" % hud.use_label(), 3.5)
			else:
				hud.shout("RUN — the gate drops soon", 2.5)
		DrGame.Phase.RUN:
			hud.shout("GO", 1.4)

			if game.effects != null:
				var _flashed := game.effects.flash(&"go")
		DrGame.Phase.SHOWDOWN:
			if is_activator():
				hud.shout("A RUNNER MADE IT — to the end with you", 3.0)
			else:
				hud.shout("SOMEBODY MADE IT — the activators are at the end", 3.0)


## Whether this client's own player is pressing buttons this round.
func is_activator() -> bool:
	return player != null and game != null and game.team_of(player.player_id) == DrGame.ACTIVATORS


## The course's file sets the client-side rules it predicts with (gravity, auto-hop); the last course's come back.
func _apply_map_config(stage_id: StringName) -> void:
	if platform == null or game == null:
		return
	if platform.map_config_keys.is_empty():
		platform.map_config_keys = DrMapConfig.client_keys()
		platform.map_config_game = DrMapConfig.GAME
		platform.map_config_get_fn = func(key: String) -> Variant:
			return str(game.config.gravity) if key == "dr_gravity" else ("1" if game.config.auto_bunny_hop else "0")
		platform.map_config_set_fn = func(key: String, value: Variant) -> bool:
			if key == "dr_gravity":
				game.config.gravity = float(str(value))
			else:
				game.config.auto_bunny_hop = str(value) in ["1", "true"]
			return true
	platform.map_changed(String(stage_id))


## A new course. The name, once, big.
func _on_stage(stage_id: StringName) -> void:
	_apply_map_config(stage_id)
	# The new course's toys are heard: a ball's bounce off a crusher.
	if game.stage != null and game.stage.toys != null and not game.stage.toys.sound.is_connected(_toy_sound):
		var _c := game.stage.toys.sound.connect(_toy_sound)

	if ragdolls != null:
		# A body on the old course would hang in the new one's air.
		ragdolls.clear()

	if game.stage == null:
		return

	if audio != null:
		audio.on_course(stage_id, game.stage.doc)

	var name_of := str(game.stage.doc.get("name", ""))
	var blurb := str(game.stage.doc.get("blurb", ""))

	hud.shout(name_of, 3.0)

	if chat != null and name_of != "":
		var author := str(game.stage.doc.get("author", ""))
		chat.say_locally("%s%s — %s" % [name_of, " by %s" % author if author != "" else "", blurb],
			Color(0.80, 0.90, 1.0))


## A runner reached the end. What the feed and the speakers say.
func _on_finished(session_id: int, place: int, seconds: float) -> void:
	var who: DrPlayer = game.players.get(DrNetBridge.player_key(session_id))

	if killcam != null:
		killcam.note_moment(DrNetBridge.player_key(session_id), "reached the end #%d" % place)
	var mine := session_id == _watch_id

	if audio != null:
		var _heard := audio.on_finish(mine)

	if mine:
		hud.shout("MADE IT #%d — %.1f s. Now the activator." % [place, seconds], 3.0)

	if chat != null and who != null:
		chat.say_locally("%s made it to the end #%d in %.1f s" % [who.display_name, place, seconds],
			Color(0.98, 0.86, 0.40))


## A trap went. A sound where it is, and a shake if it is near enough to matter.
func _on_trap(index: int, _tick: int, by: int) -> void:
	if game.stage == null or index < 0 or index >= game.stage.trap_count():
		return

	var at := game.stage.trap_zone(index).get_center()

	if audio != null:
		var spec: Variant = game.stage.traps[index].get("spec", {})
		var _heard := audio.on_trap(at, spec if spec is Dictionary else {})

	if game.effects != null and camera != null:
		game.effects.viewer_position = camera.global_position
		game.effects.shake_at(&"trap", at, 8.0)

	if by == _watch_id and hud != null:
		hud.shout(game.stage.trap_name(index), 1.0)


# --- The end of a round: killcam, winner reveal, board -------------------------

## The round's last moment, a death or a finish. A shot puts the victim in the shooter's eyes,
## anything else (a trap, the pit, a fall) in the victim's own.
func _note_death(victim: StringName, by: StringName, why: StringName) -> void:
	if killcam == null:
		return
	var who: DrPlayer = game.players.get(victim)
	var name_of := who.display_name if who != null else String(victim)
	if by != &"" and game.players.has(by) and by != victim:
		killcam.note_moment(by, "put down", name_of)
		return
	var what := "caught by a trap"
	match why:
		DrGame.DIED_PIT:
			what = "went in the pit"
		DrGame.DIED_FELL:
			what = "fell"
		DrGame.DIED_SHOT:
			what = "put down at the end"
	killcam.note_moment(victim, what)


func _build_killcam() -> void:
	killcam = DrKillcam.new()
	killcam.name = "RoundKillcam"
	killcam.players_fn = func() -> Array: return game.players.values() if game != null else []
	killcam.player_for_fn = func(key: StringName) -> Variant: return game.players.get(key) if game != null else null
	killcam.feet_fn = func(p: DrPlayer) -> Vector3: return drawn_position(p, _is_remote(p))
	killcam.colour_fn = func(p: DrPlayer) -> Color: return game.side_colour(game.team_of(p.player_id))
	killcam.seconds_fn = func() -> float: return _killcam_sec if _killcam_sec >= 0.0 else game.config.killcam_seconds
	killcam.hide_while_playing = [hud, chat]
	killcam.over.connect(func(_skipped: bool) -> void: _reveal_round())
	add_child(killcam)
	winner_reveal = DotWinnerReveal.new()
	winner_reveal.name = "WinnerReveal"
	winner_reveal.skip_actions = DrKillcam.SKIP_ACTIONS
	winner_reveal.hold_seconds = 4.0
	winner_reveal.finished.connect(_on_reveal_finished)
	add_child(winner_reveal)


## True for a player some other process simulates (the interpolator places them).
func _is_remote(p: DrPlayer) -> bool:
	return net != null and net.is_running() and p != player


## `mp_killcam_time`, from the server's replicated cvar.
func _on_killcam_cvar(cvar_name: String, value: String) -> void:
	if cvar_name == "mp_killcam_time" and value.strip_edges().is_valid_float():
		_killcam_sec = clampf(value.to_float(), 0.0, 30.0)


func _begin_round_end(number: int, why: String) -> void:
	_round_end_number = number
	_round_end_why = why
	_round_ending = true
	if killcam == null or not killcam.round_ended():
		return
	DotLog.debug(CHANNEL, "the winner waits for the killcam")


## The top three on a podium, after the killcam and before the board.
func _reveal_round() -> void:
	if not _round_ending:
		return
	var rows: Array = []
	for key: StringName in game.players:
		rows.append(game.players[key])
	rows.sort_custom(func(a: DrPlayer, b: DrPlayer) -> bool: return a.points > b.points)
	var entries: Array = []
	for who: DrPlayer in rows.slice(0, 3):
		entries.append({"name": who.display_name, "score": "%d %s" % [who.points, "point" if who.points == 1 else "points"],
			"colour": game.side_colour(game.team_of(who.player_id))})
	winner_reveal.reduced_motion = settings != null and settings.settings != null and settings.settings.get_bool(&"reduce_motion", false)
	var shown := winner_reveal.present(entries, {"title": "ROUND %d" % _round_end_number,
		"subtitle": _round_end_why.substr(0, 1).to_upper() + _round_end_why.substr(1) if _round_end_why != "" else "Round over", "hint": "Jump to skip"})
	if not shown.ok:
		_open_round_board()
		return
	if hud != null:
		_hud_was_visible = hud.visible
		hud.visible = false


func _on_reveal_finished(_skipped: bool) -> void:
	if hud != null and not killcam.is_playing():
		hud.visible = _hud_was_visible
	if _round_ending:
		_open_round_board()


func _open_round_board() -> void:
	if board != null and not board.is_open():
		board.open()
		_round_board_open = true


## A new round: whatever is still up goes, so it never covers the start.
func _end_round_presentation() -> void:
	_round_ending = false
	if killcam != null:
		killcam.skip()
	if winner_reveal != null:
		winner_reveal.skip()
	if _round_board_open and board != null:
		board.close()
	_round_board_open = false


func _killcam_frame() -> void:
	if killcam != null and game != null:
		killcam.frame()


func _on_round(number: int, began: bool, _winner: int, why: String = "") -> void:
	if audio != null:
		var _heard := audio.on_round(began)

	if began:
		hud.shout("ROUND %d" % number, 2.4)
		_end_round_presentation()
		return

	hud.shout(why if why != "" else "round over", 4.0)
	_begin_round_end(number, why)

	if chat != null and why != "":
		chat.say_locally(why, Color(0.98, 0.86, 0.40))


func _on_death(session_id: int, by: int, why: StringName) -> void:
	var id := DrNetBridge.player_key(session_id)
	var who: DrPlayer = game.players.get(id)

	_note_death(id, DrNetBridge.player_key(by) if by > 0 else &"", why)

	_hear_death(who, why)

	if chat == null:
		return

	var name_of := who.display_name if who != null else String(id)

	var line := "%s is out" % name_of

	match why:
		DrGame.DIED_TRAP:
			line = "%s was caught by a trap" % name_of
		DrGame.DIED_PIT:
			line = "%s went in the pit" % name_of
		DrGame.DIED_FELL:
			line = "%s fell" % name_of
		DrGame.DIED_SHOT:
			line = "%s was put down at the end" % name_of

	chat.say_locally(line, Color(0.80, 0.82, 0.86))


# --- What it sounds like -----------------------------------------------------

## The player's settings, applied to everything that reads them. See [DrSettings].
##
## After the audio and the sampler, because both are bound here and a binding applies at
## once. The camera arrives with the player and is bound in [method _adopt].
func _build_settings() -> void:
	settings = DrSettings.new()
	settings.name = "Settings"
	add_child(settings)
	platform.settings = settings
	# Not handed over: DrHud is a CanvasLayer and the platform's hud is a Control, so it follows
	# the menu's theme itself, below.
	platform.chat = chat
	platform.look_position_fn = _look_position
	platform.board_snapshot_fn = board_snapshot
	# M: the course list. Solo a choice changes the course here at once; connected the server
	# decides, by the owner's `sv_map_menu_flag`, and anybody without it gets a vote instead
	# (dot-vote's map menu, wired in [DrModule]).
	platform.maps_rows_fn = func() -> Array: return game.course_rows() if game != null else []
	platform.maps_change_fn = func(id: StringName) -> DotResult: return game.change_course_now(id)
	platform.maps_title = "Change course"
	platform.maps_noun = "courses"
	DotLog.result(CHANNEL, "the platform", platform.setup())
	# The starter set: the equipped list needs a credential the client does not hold (the server reads it).
	DotLog.result(CHANNEL, "avatar actions", platform.add_avatar_actions(net, _avatar_figure))
	# Walking is off while the cover is up, a menu is open or a line is typed: the sampler polls
	# the keyboard, and a player dragging a volume slider with the arrow keys would otherwise
	# walk off whatever they had stopped on.
	platform.input_blocked_changed.connect(_suspend_input)
	_suspend_input(platform.is_input_blocked())

	settings = platform.settings as DrSettings
	_add_noblock_and_workbench()
	console = platform.console as DotConsoleController
	if settings == null:
		return

	if _sampler != null:
		settings.bind_look(_sampler.tunables)

	if audio != null:
		settings.bind_audio(audio.manager)
		# The server's dr_ambient* drive the quiet layer; the player's sliders multiply on top.
		if audio.ambient != null:
			audio.ambient.follow_settings(settings.settings, game.ambient_rules)

	if hud != null and settings.menu != null:
		hud.follow_menu(settings.menu)
	board = platform.board as DotMenuScoreboard
	_dress_board()


func _build_audio() -> void:
	audio = DrAudio.new()
	audio.name = "Sound"
	add_child(audio)

	var ready_now := audio.setup()

	if not ready_now.ok:
		# A game that cannot make a noise still plays; it is the state this one shipped in.
		DotLog.warn(CHANNEL, "no sound", {"why": ready_now.error.message})
		remove_child(audio)
		audio.queue_free()
		audio = null
		return


## Offline: the world IS the authority, so its own signals are what happened.
##
## [b]Two sources and one set of sounds.[/b] A connected client hears the same things from
## the bridge's signals instead (see [method _hear_the_wire]); both call the same [DrAudio]
## method with the same arguments, so offline and online can only differ in where a fact
## came from and never in what it sounds like.
func _hear_the_world() -> void:
	if game == null:
		return

	game.world_rebuilt.connect(func() -> void:
		_on_stage(game.stage.id()))
	game.phase_changed.connect(_on_phase)
	game.round_began.connect(func(n: int, _course: StringName) -> void:
		_on_round(n, true, 0))
	game.round_over.connect(func(n: int, winner: int, why: String) -> void:
		_on_round(n, false, winner, why))
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void:
		_note_death(id, by, why)
		_hear_death(game.players.get(id), why))
	game.player_finished.connect(func(id: StringName, place: int, seconds: float) -> void:
		if killcam != null:
			killcam.note_moment(id, "reached the end #%d" % place)
		_on_finished(DrNetBridge.session_of(id) if id != &"local" else _watch_id, place, seconds))
	game.trap_fired.connect(func(index: int, tick: int, by: StringName) -> void:
		_on_trap(index, tick, DrNetBridge.session_of(by) if by != &"local" else _watch_id))
	game.button_refused.connect(func(id: StringName, why: String) -> void:
		if id == &"local" and chat != null:
			chat.notice(why)
			if audio != null:
				var _denied := audio.deny())
	game.player_armed.connect(func(id: StringName, weapon: StringName) -> void:
		if id == &"local":
			_on_armed(_watch_id, weapon)
	)

	if audio == null:
		return

	# Everybody else's weapons, from each rig as it is built.
	game.player_armed.connect(func(id: StringName, _weapon: StringName) -> void:
		var armed: DrPlayer = game.players.get(id)
		if armed == null or armed == player or armed.weapons == null:
			return
		if armed.weapons.used.is_connected(_on_rig_used.bind(armed)):
			return
		armed.weapons.used.connect(_on_rig_used.bind(armed))
	)


func _on_rig_used(outcome: DotWeaponOutcome, armed: DrPlayer) -> void:
	if audio != null and is_instance_valid(armed):
		var _heard := audio.on_weapon(armed.global_position, ZeeWeaponNet.kind_number(outcome.kind))


## Connected: the same sounds, from what the server said.
func _hear_the_wire() -> void:
	if audio == null or bridge == null:
		return

	bridge.weapon_used_by.connect(func(session_id: int, _times: int, kind: int) -> void:
		# Your own is heard from your own rig, a round trip sooner. See `_arm_locally`.
		if session_id == _watch_id:
			return
		var who: DrPlayer = game.players.get(DrNetBridge.player_key(session_id))
		if who != null:
			var _heard := audio.on_weapon(who.global_position, kind))
	bridge.notice_received.connect(func(_text: String) -> void:
		var _heard := audio.deny())


func _hear_phase(phase: int) -> void:
	if audio == null:
		return

	match phase:
		DrGame.Phase.RUN:
			var _heard := audio.on_gate()
		DrGame.Phase.SHOWDOWN:
			var _heard := audio.on_showdown()


func _hear_death(who: DrPlayer, why: StringName) -> void:
	_fall(who)

	if audio == null or who == null:
		return

	var _heard := audio.on_death(who.global_position, who == player)


## Somebody got a weapon. If it was us, the gun comes up in our hands, on its own slot.
func _on_armed(session_id: int, weapon_id: StringName) -> void:
	if session_id != _watch_id:
		return

	_arm_locally(weapon_id)

	if chat != null:
		chat.say_locally("You were handed a %s." % String(weapon_id).replace("_", " "),
			Color(0.86, 0.92, 0.80))


# --- The weapons, drawn ----------------------------------------------------

## Builds a view model for this player's own hands when they are handed a weapon.
##
## [b]Drawn, never decided, and `authority` is false for exactly that reason.[/b] The server
## owns every shot; what this is for is a gun that moves. A player whose weapon never
## deploys, never reloads and never kicks is a player who cannot tell a weapon that is ready
## from one that is not.
func _arm_locally(weapon_id: StringName = &"") -> void:
	if player == null:
		return

	if weapons != null:
		_give_locally(weapon_id)
		_select_locally(weapon_id)
		return

	if camera == null:
		_build_camera()

	if camera == null:
		return

	view_model = ZeeViewModel.new()
	view_model.name = "ViewModel"
	camera.add_child(view_model)

	weapons = ZeeWeaponRig.new()
	weapons.name = "Weapons"
	weapons.role = ZeeWeaponRig.Role.LOCAL
	weapons.authority = false
	weapons.tick_rate = game.tick_rate
	weapons.view_model_ref = DotNodeRef.of_path(view_model.get_path())
	weapons.player_ref = DotNodeRef.of_path(player.get_path())
	player.add_child(weapons)

	var ready_now := weapons.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "the view model would not set up", {
			"why": ready_now.error.message,
		})
		_disarm_locally()
		return

	# [b]Only what the server armed, one weapon as each is armed[/b] (`player_armed` / ARMED),
	# never the whole pack. `give_everything` put all of it in five slots, so a slot held
	# whichever weapon was given last and the drawn gun was not the one the server fired
	# (mg-prop-hunt's play test: "weapons appear with no slot logic").
	_give_locally(weapon_id)

	# Your own shots, from your own rig: a predicted use, heard the tick it happens rather
	# than when the server's snapshot says it did. At the camera, so it is at full volume.
	weapons.used.connect(func(outcome: DotWeaponOutcome) -> void:
		if audio != null and camera != null:
			var _heard := audio.on_weapon(
				camera.global_position, ZeeWeaponNet.kind_number(outcome.kind)
			)
	)

	_select_locally(weapon_id)


## Puts the weapon just picked up in hand, on its own slot, here and in what is sent.
func _select_locally(weapon_id: StringName) -> void:
	if weapons == null or weapon_id == &"":
		return

	var def := weapons.arsenal.catalogue.get_def(weapon_id)

	if def != null:
		_slot = def.slot


func _give_locally(weapon_id: StringName) -> void:
	if weapons == null or weapon_id == &"":
		return
	if weapons.arsenal != null and weapons.arsenal.carries(weapon_id):
		return
	var given := weapons.give(weapon_id)
	if not given.ok:
		DotLog.warn(CHANNEL, "the drawn rig refused a weapon", {"weapon": String(weapon_id), "why": given.error.message})


func _disarm_locally() -> void:
	if weapons != null:
		player.remove_child(weapons)
		weapons.queue_free()
		weapons = null

	if view_model != null and is_instance_valid(view_model):
		view_model.queue_free()
		view_model = null


# --- The camera ------------------------------------------------------------

func _build_camera() -> void:
	if camera != null or player == null:
		return

	camera = Camera3D.new()
	camera.name = "Eye"
	camera.fov = 92.0
	camera.current = true

	# Other players and stand-ins: hidden when one is at the lens, faded in third person when
	# one stands between the camera and you. It rides the camera wherever the camera goes.
	# Handed the figures rather than found by a query: a player's hull is off while
	# mp_solidplayers is 0, and a body walking through you is exactly when it is needed.
	_fade = DotCameraFade.new()
	_fade.name = "Fade"
	_fade.bodies_fn = _other_players
	camera.add_child(_fade)

	if not game.view_rules.changed.is_connected(_on_view_rules_changed):
		game.view_rules.changed.connect(_on_view_rules_changed)
	third_person = game.view_rules.resolve(third_person)

	_place_camera()


## Puts the camera where this view mode wants it, rebuilding the rig if the mode changed.
##
## [b]A boom in third person and nothing in first.[/b] dot-core's [DotCameraBoom] sweeps a
## sphere from the eye and eases in ahead of a wall or a gantry; the spring arm it replaced
## cast a ray from a pivot above the head and snapped to whatever it hit.
func _place_camera() -> void:
	if camera == null or player == null:
		return

	var eye := DrPlayer.EYE_HEIGHT

	if camera.get_parent() != null:
		camera.get_parent().remove_child(camera)

	if _arm != null and is_instance_valid(_arm):
		_arm.queue_free()
		_arm = null

	if not third_person:
		player.add_child(camera)
		_rig_height = eye
		camera.position = Vector3(0.0, eye, 0.0)
		camera.rotation = Vector3.ZERO
		if _fade != null:
			_fade.focus = null
		return

	_arm = DotCameraBoom.new()
	_arm.name = "Chase"
	_arm.spring_length = CHASE_BACK
	# The level, never players: they are faded instead (a stand-in behind you would pull the
	# camera into your head).
	_arm.collision_mask = _level_mask()
	_arm.add_excluded_object(player.get_rid())
	# Swept from the eye, the height above it added in the world's up: a pivot above the
	# head can itself be inside a beam, and a sweep that starts inside does not see it.
	_rig_height = eye
	_arm.lift = CHASE_UP - eye
	_arm.position = Vector3(0.0, _rig_height, 0.0)
	player.add_child(_arm)

	_arm.add_child(camera)
	camera.position = Vector3.ZERO
	camera.rotation = Vector3.ZERO
	if _fade != null:
		_fade.focus = _arm


## Swaps the view, where the server's `mp_forceview` allows. Presentation only: the
## simulation does not know which one is on.
func toggle_view() -> void:
	var wanted := game.view_rules.toggled(third_person)
	if wanted == third_person:
		if hud != null and game.view_rules.refusal() != "":
			hud.shout(game.view_rules.refusal(), 1.6)
		return
	third_person = wanted
	_place_camera()

	if audio != null:
		var _heard := audio.click()

	if hud != null:
		hud.shout("third person" if third_person else "first person", 1.2)


## Everybody but this player, for the camera fade.
func _other_players() -> Array:
	var out: Array = []
	if game == null:
		return out
	for id in game.players:
		var other: Node3D = game.players[id]
		if other != player and is_instance_valid(other):
			out.append(other)
	return out


## What the third-person and spectator cameras stop against: the course and the props.
func _level_mask() -> int:
	return game.physics.mask_of([&"world", &"prop"]) if game.physics != null else 1


## The server changed `mp_forceview`: the view it allows now.
func _on_view_rules_changed() -> void:
	var allowed := game.view_rules.resolve(third_person)
	if allowed != third_person:
		third_person = allowed
		if not is_spectating():
			_place_camera()


func _build_hud() -> void:
	hud = DrHud.new()
	# The counter reads the gun this player sees (corrected from the server's by correct_drawn).
	hud.weapons_fn = func() -> ZeeWeaponRig: return weapons
	hud.name = "Hud"
	hud.use_key = USE_KEY
	hud.use_action = DrBindings.USE
	add_child(hud)


## The chat box, before the netcode and before any player exists.
##
## [b]Built in both halves and attached to the bridge afterwards.[/b] A box built after the
## first line arrived would miss it — the backlog a joining player is sent is the first thing
## the server says.
func _build_chat() -> void:
	chat = new_chat()
	add_child(chat)


## Walking off and on: typing, or the settings screen up. Both samplers, because offline the
## player samples for themselves and connected the client does.
## dot-team's block rules followed from the server, and the F9 tuning panel where this process hosts the game.
func _add_noblock_and_workbench() -> void:
	if link != null:
		DotLog.result(CHANNEL, "noblock", platform.add_noblock(game, Callable(game, "team_of_side")))
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.listen_host_fn = func() -> bool: return true
	wb.config = {"enabled": false}
	if game.config_binder != null:
		for set: DotProfileSet in game.config_binder.profile_sets():
			wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	add_child(wb)
	var started := wb.start()
	DotLog.result(CHANNEL, "the workbench", started)
	if started.ok and game.config_binder != null:
		game.config_binder.attach(wb.api.runtime)
	platform.add_workbench(wb)


## Online: no local trust and no panel until the server names this player an admin (sv_workbench_remote). The rows are the server's, through the bridge's profile link.
func _start_remote_workbench() -> void:
	if workbench_remote == null:
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.remote_client = workbench_remote
	wb.remote_fn = func() -> bool: return true
	wb.config = {"enabled": false}
	if game.config_binder != null:
		for set: DotProfileSet in game.config_binder.profile_sets():
			wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	add_child(wb)
	var started := wb.start(game.ensure_runtime())
	DotLog.result(CHANNEL, "the remote workbench", started)
	if not started.ok:
		wb.queue_free()
		return
	workbench = wb
	platform.add_workbench(wb)


func _suspend_input(suspended: bool) -> void:
	if _sampler != null:
		_sampler.suspended = suspended

	if player != null and player.sampler != null:
		player.sampler.suspended = suspended


## Whether the pointer is the game's: captured. A menu frees it and the platform takes it back.
func _pointer_ours() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


# --- The frame -------------------------------------------------------------

## The sampled command, on a connected client, once per tick the clock says has passed.
##
## [b]Offline this does nothing and the world ticks itself.[/b] The player samples inside
## [method DrPlayer.simulate] there, which is the shape a single process wants; a connected
## client cannot use it, because its local player has to be simulated by the PREDICTOR from
## the same command that was sent, and a second sample would predict something different from
## what the server was told.
func _physics_process(delta: float) -> void:
	if _offline:
		_drive_offline(delta)
		return

	if net == null or not net.is_running() or bridge == null:
		return

	# The clock says how many ticks this frame is worth, which on a client whose engine runs
	# at the server's rate is almost always exactly one.
	var ticks := net.clock.advance(delta)

	# The clock has advanced; only the sampling waits, so the mouse does not pile up a turn
	# behind the cover and the server sees an idle body until it lifts.
	if _covered():
		return

	var move := _sampler.sample(delta) if _sampler != null else DotFpsCommand.new()
	_stamp(move)

	# [b]Each pass is its own tick.[/b] `advance` has already moved the clock by all of
	# them, so `input_tick()` is the LAST one on every pass: a frame worth two ticks sent
	# the second twice and the first never, the server repeated a stale command for the
	# one it never got, and the predictor's replay stopped at the hole and drew the player
	# short of where they were -- after every hitch, and on every frame the display and
	# the tick rate do not line up. Arithmetic here rather than a new dot-net call,
	# because a pack has to run on whatever client shell the player already has.
	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), move, _slot, _use)

	# A teleport turns the predicted body in the tick; the mouse's own angles are this sampler's,
	# and the next command would turn them back. Read after the tick, so a replay that crossed
	# the same teleport re-aims to wherever the body is looking by then and costs no turn.
	if player != null and _sampler != null and player.warps != _seen_warps:
		_seen_warps = player.warps
		_sampler.look_at_angles(player.controller.state.yaw, player.controller.state.pitch)

	_drive_view_model(move)


## Offline the world samples for itself; what is left is the buttons this file owns.
func _drive_offline(_delta: float) -> void:
	if player == null or player.sampler == null:
		return

	var pending := player.controller.current_command

	if pending != null:
		_stamp(pending)
		player.wanted_slot = _slot

	player.wants_use = _use and not _covered()

	_drive_view_model(pending)


## Puts this game's three buttons and the slot onto a command.
func _stamp(command: DotFpsCommand) -> void:
	if command == null:
		return

	command.set_button(DrNetCommand.BUTTON_FIRE, _firing)
	command.set_button(DrNetCommand.BUTTON_ALT, _alt)
	command.set_button(DrNetCommand.BUTTON_RELOAD, _reloading)

	if is_roaming():
		# The roaming spectator flies a camera and does not walk the dead body about. Here and
		# not in the physics frame, so the offline world's own sample (`command_stamp`) is
		# zeroed too, which is the gap a previous roaming client left open.
		command.move = Vector2.ZERO
		command.buttons = 0


## A hit the server confirmed for this player's shot: the marker, and zee's red burst on the body
## at the server's point (`ZeeShotFx.play_body_hit`, by `has_method` for an older shell's zee;
## it skips a burst its own presentation ray already drew).
func _on_hit(point: Vector3, killed: bool, headshot: bool) -> void:
	if hud != null:
		hud.confirm_hit(killed, headshot)
	if weapons == null or not is_instance_valid(weapons) or not weapons.has_method(&"shot_fx"):
		return
	var fx: Object = weapons.call(&"shot_fx")
	if fx == null or not fx.has_method(&"play_body_hit"):
		return
	var from: Vector3 = camera.global_position if camera != null else point + Vector3.UP
	fx.call(&"play_body_hit", point, point - from)


func _process(delta: float) -> void:
	_pose_stage()

	var _shown := present_frame(
		net, game, player, not third_person, delta, -1.0, _watched_through_eyes()
	)

	_present_course(delta)
	_killcam_frame()

	if camera == null or player == null:
		return

	# [b]Before the rig, and instead of it.[/b] The rig below hangs the camera off the
	# player's own node, and a player who is out is a body at the kill height.
	if _drive_spectator_camera():
		_present_effects(delta)
		return

	# Drawn every FRAME from the controller's own interpolated view, not once per tick.
	# Another game in this family measured what the other way costs: a client stepping physics
	# at one rate and drawing at another advances the camera in bursts, which is a 47% change
	# in apparent speed several times a second and reads as "the game is jittery" with every
	# simulated number correct.
	var state := player.controller.state
	var pitch := deg_to_rad(state.pitch)
	var yaw := deg_to_rad(state.yaw)

	var rig: Node3D = camera

	if _arm != null and is_instance_valid(_arm):
		rig = _arm

	# The camera's half of the weapon's recoil. Added here rather than by the weapon,
	# because this line writes the angles from scratch every frame and would undo it; and
	# only here, never to the command — the shot already went where the command pointed.
	if weapons != null:
		var punch := weapons.view_punch()
		pitch += deg_to_rad(punch.x)
		yaw += deg_to_rad(punch.y)

	rig.rotation = Vector3(pitch, yaw, 0.0)

	# [b]And the position from between the last two ticks, which the angles above never
	# needed.[/b] The rig hangs off the player's node and the node only moves on a tick, so
	# a camera left there advances in steps: measured offline at 64 ticks and 144 frames,
	# 160 frames in 288 did not move at all while the player ran, and the per-frame step
	# varied by 112%. `render_state` blends the last two ticks by the engine's own physics
	# fraction, which this client makes a fraction through a tick by running the engine at
	# the world's rate. Written globally rather than by moving the node, because the tick
	# writes the node and prediction reads it back.
	#
	var drawn := player.controller.render_state()
	rig.global_position = drawn.position + Vector3(0.0, _rig_height, 0.0)

	if weapons != null:
		var speed := Vector2(state.velocity.x, state.velocity.z).length()
		weapons.drive_view(
			Vector2(state.yaw, state.pitch),
			speed,
			state.mode != DotFpsState.Mode.AIR,
			state.crouch_fraction > 0.5
		)

	_present_effects(delta)


## Whether this client's own player is out and watching somebody.
func is_spectating() -> bool:
	return player != null and game != null and game.spectate != null \
		and game.spectate.is_spectating(player.player_id)


## The player whose eyes this camera is behind, so their body is not drawn around it.
func _watched_through_eyes() -> DrPlayer:
	if not is_spectating():
		return null

	var mode := game.spectate.mode_of(player.player_id)

	if mode != DotSpectatorView.Mode.FIRST_PERSON and mode != DotSpectatorView.Mode.FREEZE_CAM:
		return null

	return game.players.get(game.spectate.watching(player.player_id))


## Puts the camera where [DrSpectate] says, and takes it back when a round starts.
##
## [b]The camera leaves the player's node while they watch.[/b] Setting a global transform
## on a camera hung under the chase arm is undone by the arm on its next frame, and one hung
## under the body is under a body that is not where anything worth seeing is. So it is moved
## to this node for as long as the player is out and handed back by `_place_camera` — the
## same call a view swap uses — the moment they are not.
##
## Once a FRAME, like the rig: the target's pose is the drawn one, so a camera moved on the
## tick would step at the tick rate however smoothly the target is drawn.
func _drive_spectator_camera() -> bool:
	if not is_spectating():
		if camera.get_parent() == self:
			_place_camera()

			if view_model != null and is_instance_valid(view_model):
				view_model.visible = true

		if hud != null:
			hud.set_watching("")

		return false

	if camera.get_parent() != self:
		camera.get_parent().remove_child(camera)
		add_child(camera)
		camera.current = true

		if _arm != null and is_instance_valid(_arm):
			_arm.queue_free()
			_arm = null

	# A view model left on is somebody else's gun drawn in front of the camera.
	if view_model != null and is_instance_valid(view_model):
		view_model.visible = false

	# Chase and death cameras pulled out of the course by dot-spectate, given the level.
	var manager: DotSpectatorManager = game.spectate.manager
	if manager != null and manager.camera_world == null and game.physics != null:
		manager.camera_world = camera.get_world_3d()
		manager.camera_mask = _level_mask()

	var where := game.spectate.camera_for(player.player_id)

	if game.spectate.is_roaming(player.player_id):
		where = _fly_free_camera()
	else:
		_free_cam = null

	# Identity is dot-spectate's "no answer" — a target it could not find. Holding the last
	# frame is better than a camera at the world origin.
	if where != Transform3D.IDENTITY:
		camera.global_transform = where

	if hud != null:
		game.spectate.roam_key = _key(DrBindings.ROAM)
		hud.set_watching(game.spectate.line_for(player.player_id))

	return true


## The free-roam key: into a free camera while out, and back onto a player from it. On a
## connected client the server decides (it owns the mode, and says no with a notice when
## `mp_freeroam 0` or `mp_forcecamera` forbids it); offline the local world is the server.
func toggle_roam() -> void:
	if not is_spectating():
		return

	_free_cam = null
	_roam_look = Vector2.ZERO

	if bridge != null:
		bridge.ask_roam()
		return

	var res := game.spectate.toggle_roam(player.player_id)

	if not res.ok and chat != null:
		chat.notice(res.error.message)


func is_roaming() -> bool:
	return game != null and game.spectate != null and player != null \
		and game.spectate.is_roaming(player.player_id)


## One frame of the free camera: the mouse turn folded in, then the movement keys. Seeded from
## where the camera was on the first frame of a roam, so it starts where the spectator looked.
## The pose is kept in the manager too, so a later hand-over starts from it.
func _fly_free_camera() -> Transform3D:
	if _free_cam == null:
		_free_cam = DotSpectatorFreeCam.new()
		_free_cam.rules = game.spectate_rules
		_free_cam.seed_from(camera.global_transform)

	var sens := deg_to_rad(_sampler.tunables.mouse_sensitivity) if _sampler != null else 0.0025
	_free_cam.look(Vector2(-_roam_look.x, -_roam_look.y) * sens)
	_roam_look = Vector2.ZERO

	var move := Vector3.ZERO

	if _pointer_ours() and not _covered():
		move = Vector3(
			_strength(&"dot_fps_right") - _strength(&"dot_fps_left"),
			_strength(&"dot_fps_jump") - _strength(&"dot_fps_crouch"),
			_strength(&"dot_fps_forward") - _strength(&"dot_fps_back"),
		)

	var pose := _free_cam.step(
		move, _held(&"dot_fps_sprint"), _held(&"dot_fps_walk"), get_process_delta_time()
	)
	var _kept := game.spectate.manager.move_free(String(player.player_id), pose.origin, pose.basis)
	return pose


static func _strength(action: StringName) -> float:
	return Input.get_action_strength(action) if InputMap.has_action(action) else 0.0


static func _held(action: StringName) -> bool:
	return InputMap.has_action(action) and Input.is_action_pressed(action)


## The key an action is on, as the player has it bound.
func _key(action: StringName) -> String:
	if settings != null and settings.bindings != null:
		var text := settings.bindings.key_for(action)
		if text != "":
			return text

	var row := DrBindings.make().row_for_action(action)
	return str(row.get("default", action))


## Asks for the next or previous person to watch, or the other camera.
func spectate_step(direction: int) -> void:
	if audio != null:
		var _heard := audio.click()

	if bridge != null:
		bridge.ask_spectate(direction)
		return

	if game == null or game.spectate == null or player == null:
		return

	var moved := game.spectate.step(player.player_id, direction)

	if not moved.ok and chat != null:
		chat.notice(moved.error.message)

		if audio != null:
			var _denied := audio.deny()


func _unhandled_input(event: InputEvent) -> void:
	# Tab, M and a click taking the pointer back are the platform's (DotGameClient).
	if event.is_action_pressed("ui_cancel"):
		# Opens the settings when the menu left this Escape alone, because a released pointer
		# with nothing on screen to click was a key that did half a job.
		# A second Escape never reaches here: dot-ui's stack
		# sits deeper in the tree, sees it first, and closes the screen.
		if settings != null:
			settings.open()
		return

	# Nothing below acts while the cover is up: no fire, use, reload or slot.
	if _covered():
		return

	# The wheel, on dot-menu's previous/next weapon actions (rebindable). Only with the pointer
	# captured and a weapon in hand: spectators and a menu get no weapon change.
	if event is InputEventMouseButton and event.pressed and _pointer_ours() and not is_spectating():
		var step := 0
		if event.is_action_pressed(DotMenuBindings.WEAPON_NEXT_ACTION):
			step = 1
		elif event.is_action_pressed(DotMenuBindings.WEAPON_PREVIOUS_ACTION):
			step = -1
		if step != 0:
			var cycled := _cycled_slot(step)
			if cycled != 0:
				_slot = cycled
			return

	# The game's keys, each a row of [DrBindings] read through its action, so a key moved on
	# the Controls page moves what it does here.
	if event is InputEventKey:
		if event.is_action_pressed(DrBindings.ROAM) and is_spectating():
			toggle_roam()
			return

		if event.is_action_pressed(DrBindings.VIEW):
			# Out, the key swaps the SPECTATOR's camera, which the server decides.
			if is_spectating():
				spectate_step(0)
			else:
				toggle_view()
			return

		# The slots. One to five, which is what the pack uses.
		for i in range(DrBindings.SLOTS.size()):
			if event.is_action_pressed(DrBindings.SLOTS[i]):
				_slot = i + 1
				return

		if event.is_action(DrBindings.RELOAD):
			_reloading = event.is_pressed()
			return

		if event.is_action(DrBindings.USE):
			# Held, and sent every tick in this game's own input message; the server makes the
			# edge. A request instead would be a press resolved a round trip after the key,
			# against a runner who has left the trap.
			_use = event.is_pressed()
			return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton

		# Out, the buttons step through who to watch. Nobody out has a weapon, and a click
		# that fired nothing and moved nothing is reported as the game having frozen.
		if is_spectating():
			_firing = false
			_alt = false

			if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
				spectate_step(1)
			elif button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
				spectate_step(-1)
			return

		if button.button_index == MOUSE_BUTTON_LEFT:
			_firing = button.pressed
		elif button.button_index == MOUSE_BUTTON_RIGHT:
			_alt = button.pressed

	if player == null:
		return

	if is_roaming() and event is InputEventMouseMotion:
		# The free camera turns on the mouse, and the dead body's view stays put.
		if _pointer_ours():
			_roam_look += (event as InputEventMouseMotion).relative
		return

	if event is InputEventMouseMotion and _pointer_ours():
		if _offline and player.sampler != null:
			player.sampler.handle_event(event)
		elif _sampler != null:
			_sampler.handle_event(event)


## The slot [param step] places along from the one in hand, over the slots carried (so an
## empty slot is skipped); 0 when there is nothing to change to.
func _cycled_slot(step: int) -> int:
	if weapons == null or weapons.arsenal == null:
		return 0
	var carried := weapons.arsenal.slots()
	if carried.size() < 2:
		return 0
	var at := carried.find(_slot if _slot != 0 else weapons.arsenal.current_slot())
	if at < 0:
		at = carried.find(weapons.arsenal.current_slot())
	return carried[posmod(at + step, carried.size())]


func describe() -> Dictionary:
	var out := {
		"offline": _offline,
		"session": _watch_id,
		"player": player != null,
		"view": "third" if third_person else "first",
		"armed": weapons != null,
		"watching": String(game.spectate.watching(player.player_id))
			if is_spectating() else "-",
	}

	if bridge != null:
		out["bridge"] = bridge.describe()

	if chat != null:
		out["chat"] = chat.describe()

	if game != null:
		out["world"] = game.describe()

	return out


## dot-game's chat box and microphone, with this game's channels and voice format. It also
## draws dot-server's own lines (the vote between games, joins, an admin's `say`), which arrive
## on the shell's client link rather than on this game's bridge. Static so a suite can build
## the same box the client does.
static func new_chat() -> DotGameChatClient:
	var box := DotGameChatClient.new()
	box.name = "Chat"
	box.channels = [
		{"id": DrServices.CH_ALL, "label": "All", "colour": Color(0.93, 0.94, 0.96)},
		{"id": DrServices.CH_TEAM, "label": "Team", "colour": Color(0.55, 0.82, 0.95)},
		{"id": DrServices.CH_NEAR, "label": "Near", "colour": Color(0.82, 0.86, 0.72)},
	]
	box.max_length = DrServices.chat_rules().max_length
	box.voice_config = DrServices.voice_format()
	return box


func _toy_sound(id: StringName, at: Vector3, strength: float) -> void:
	if audio != null:
		var _played := audio.on_toy(id, at, strength)


## Where a roster row's player stands, for dot-game's look-to-gag key (G, K).
func _look_position(row: Dictionary) -> Variant:
	if game == null:
		return null
	for who: DrPlayer in game.players.values():
		if who != player and who.display_name == row["name"]:
			return who.global_position + Vector3.UP * 1.5
	return null
