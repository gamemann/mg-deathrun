extends CharacterBody3D

const DrConfig := preload("dr_config.gd")
const DrController := preload("dr_controller.gd")
const DrCourse := preload("dr_course.gd")
const DrFigure := preload("dr_figure.gd")
const DrAvatars := preload("dr_avatars.gd")

## One person: how they move, what the course does to them, which side they are on this
## round, and what they are holding.
##
## [b]What the course does to a player inside their own tick is the carry, and only the
## carry[/b] — see [DrController]. A moving floor or a trapdoor rolling over moves whoever is
## standing on it, and that is a function of their state, the tick and the presses so far, so
## a connected client predicting itself is carried exactly as the server carries it. Whether
## something KILLED them is not predicted: it is the server's decision ([DrGame]), arriving
## as a death, because a client that decided it had died would be a client that could decide
## it had not.

const CHANNEL := "dr.player"

## Metres above a player's feet that their eyes are.
##
## Here rather than on the client, because it is where a shot leaves from as well as where
## the camera is, and the two being one number is what stops a player hitting what they are
## not looking at.
const EYE_HEIGHT := 1.6

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"

## What this player looks like, as a dot-user-avatar document; null is the stock person.
var avatar: DotAvatar = null

## Whether a command is sampled from the input devices each tick. The person at the keyboard.
@export var samples_input: bool = false

## Whether this player is driven by the game rather than by a person.
##
## [b]Separate from [member samples_input], and conflating the two is a bug waiting for
## netcode.[/b] Every remote player also samples nothing; what makes a bot a bot is that
## something here decides for them.
@export var is_bot: bool = false

var config: DrConfig = null

var controller: DrController = null
var sampler: DotFpsSampler = null
var health: DotHealth = null

## The weapons, once the end has handed them one.
var weapons: ZeeWeaponRig = null

## The course (or the arena) they are on. Set by [DrGame]; read inside the tick.
var stage: DrCourse = null

## Which side they are on this round: [constant DrGame.RUNNERS] or [constant DrGame.ACTIVATORS].
var team: int = 0

## Which side this player asked for: 0 either, RUNNERS or ACTIVATORS. Server side; read by
## the draw. See [member DrConfig.allow_side_choice].
var side_wish: int = 0

## Points this match, and the server's last ping for this player (-1 unknown). Tab board.
var points: int = 0
var ping_ms: int = -1

## The entity id dot-combat and dot-entity know them by.
var entity_id: int = 0

## How many times [method place_at] has put them somewhere. Replicated, so a watcher's
## interpolator draws a teleport as one instead of as a flight across the course.
var warps: int = 0

## Set by the tick that sent them through a teleport, cleared by [DrGame] once a stand-in has
## picked its route up from the landing. The tick itself moves them; this is only the note.
var teleported: bool = false

## Whether they have crossed the finish this round. Server side; replicated.
var finished: bool = false

## Where they finished, 1 for first. 0 until they do.
var place: int = 0

## Seconds into the run they crossed the finish.
var finish_seconds: float = 0.0

## Whether they are in the end arena: a runner who crossed, or an activator who was called.
var at_end: bool = false

## Whether they are sitting this round out: joined after it started. Not dead — nothing can
## reach them — and counted on no side, so a late joiner cannot end a round by existing.
var watching: bool = false

## Which weapon slot they have asked for, from this game's own input message.
var wanted_slot: int = 0

## Whether the use key is held — a button, for an activator — from the same message.
var wants_use: bool = false

## An administrator's `blind`: this player's own screen is blacked out. Owner-only on the wire.
var blinded: bool = false

## An administrator's `beacon`: a ring, a column and a ping every client draws.
var beacon: bool = false

var beacon_marker: DotFxBeacon = null

## What other people see this player as. Client side.
var figure: DrFigure = null

## How this player's body falls on their death: the server's pick ([method DrGame.decide_death]),
## carried on DEATH and set here before anybody hears of it. Null before a first death.
var death: DotPlayerDeath = null

# --- What a watcher draws in their hand. Client side --------------------------
#
# A player this process SIMULATES (an offline stand-in, or yourself in third person) is read
# off their own rig. One it only MIRRORS has no rig here at all — the server owns it — so it
# is drawn from two things the wire already carries: the weapons the server ANNOUNCED it
# dealt them (`DrEvents.Kind.ARMED`, one per weapon) and the slot the snapshot says is in
# hand. A slot alone names no weapon, because the pack puts several weapons in each slot;
# the dealt list alone does not say which of two is out.

## Whether [member mirror_slot] and the rest are written from a snapshot (`DrPlayerNet`).
var mirrored: bool = false

## The weapons the server said it dealt them, in the order it dealt them.
var dealt: Array[StringName] = []

## The round [member dealt] belongs to: a deal for a new round starts a new list.
var dealt_round: int = -1

var mirror_slot: int = 0
var mirror_switching: bool = false

## Uses the snapshot reported since the figure last drew them, and their kind.
var mirror_fired: int = 0
var mirror_fire_kind: int = 0

## The rig's own counter as the figure last saw it, for a simulated player.
var _seen_fire_seq: int = -1

## Every pack weapon's slot, by id. Built once per process; a slot does not depend on the
## damage table a game passes the pack.
static var _slots: Dictionary = {}

var tick_rate: int = 64:
	set(value):
		tick_rate = value
		if controller != null:
			controller.tick_rate = value


## The key [DotWeaponPlayerBridge] identifies this carrier by. Duck-typed: see mg-smash-
## copter's note, where a misspelling made every shot come from entity zero.
var player_key: String:
	get:
		return String(player_id)


func _ready() -> void:
	controller = DrController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate
	# EXTERNAL even offline: the world owns the tick, so "pose the course, move, then let the
	# course act on the player" is explicit, and it is the shape a dedicated server needs.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = tunables_for(config)
	controller.admin_abilities = true
	controller.before_fn = _before_tick
	controller.after_fn = _after_tick
	add_child(controller)

	if samples_input:
		sampler = DotFpsSampler.new(controller.tunables)
		register_actions(sampler)


## How a player moves.
##
## [b]Static, and it takes the config,[/b] for mg-smash-copter's reason: a connected client
## builds a sampler before it has a player, and a sampler built from different tunables than
## the controller it feeds is input clamped differently from the simulation that consumes it.
static func tunables_for(config: DrConfig) -> DotFpsTunables:
	var t := DotFpsTunables.new()
	t.max_speed = config.run_speed if config != null else 7.0
	t.gravity = config.gravity if config != null else 20.0
	t.jump_height = config.jump_height if config != null else 1.25

	# [b]Off unless the server says so.[/b] Every gap on a course is measured against a running
	# jump at the run speed (the suite checks it); a player who could chain hops would clear
	# gaps a mapper meant to be the hard part. `auto_bunny_hop` is the operator's.
	t.auto_hop = config.auto_bunny_hop if config != null else false

	# Shift is the walk here, as in mg-smash-copter: a narrow ledge between two traps is
	# crossed slowly, and a walk on the key everybody already reaches for is the control a
	# ledge asks for.
	t.walk_speed_scale = config.walk_speed_scale if config != null else 0.45
	t.can_walk = true
	t.can_sprint = false
	t.can_crouch = true
	t.crouch_speed_scale = 0.4

	t.accelerate = 10.0
	t.friction = 6.5
	t.stop_speed = 3.0

	# The round-based shooters' air control: enough to strafe round a corner in the air and
	# to correct a jump that was slightly off, which is what separates "I mistimed that" from
	# "the game threw me" when the floor under the landing has just opened.
	t.air_accelerate = config.air_accelerate if config != null else 30.0
	t.max_air_wish_speed = 1.4

	t.coyote_time = 0.1
	t.jump_buffer_time = 0.12

	# A bridge that rolls over is a floor tilting under somebody, and they should stay on it
	# until it is past the angle a person could stand on — then slide off it into whatever is
	# under it, which is the trap.
	t.max_slope_angle = 40.0
	t.step_height = 0.4

	return t


## Registers the movement actions, and binds the slow walk to shift. See mg-smash-copter.
static func register_actions(p_sampler: DotFpsSampler = null) -> void:
	var _added := DotFpsSampler.register_default_actions(p_sampler)
	var walk := &"dot_fps_walk"

	if not InputMap.has_action(walk):
		return

	for event in InputMap.action_get_events(walk):
		var key := event as InputEventKey

		if key != null and key.physical_keycode == KEY_SHIFT:
			return

	var shift := InputEventKey.new()
	shift.physical_keycode = KEY_SHIFT
	InputMap.action_add_event(walk, shift)


## The clear air a running player crosses in one jump, landing [param rise] metres higher.
##
## dot-player-controller's own arithmetic over this game's tunables, so a cvar that shortens
## the jump shortens every check that reads this.
static func jump_reach(config: DrConfig, rise: float = 0.0) -> float:
	return tunables_for(config).jump_reach(rise)


## Called once per simulated tick by the world, on the server and offline.
## Offline only: puts the client's buttons (fire, reload...) on the command [member sampler] has
## just made. Stamped here, after sampling: the client used to stamp
## `controller.current_command` from its own physics frame, and this function then applied a
## fresh sample over it, so offline no trigger ever reached the world's rig and no shot of the
## player's landed (game-zombie-zone's play test found it; its docs/history.md has the story).
var command_stamp: Callable = Callable()


func simulate(tick: int, delta: float) -> void:
	# The world calls this by name, so a body the load gate froze is skipped here.
	if is_inside_tree() and not can_process():
		return

	if sampler != null:
		# Settling under the cover runs the body with its input off (falls, lands, no keys).
		var gate := DotLoadGate.of(self) if is_inside_tree() else null
		var sampled := sampler.sample(delta) if gate == null or gate.is_open() else DotFpsCommand.new()

		if command_stamp.is_valid():
			command_stamp.call(sampled)

		controller.apply_command(sampled)

	controller.simulate_tick(tick, delta)


## Before the motor: the course where it is on this tick.
func _before_tick(tick: int) -> void:
	if stage != null and is_instance_valid(stage):
		stage.pose_at(tick)


## After the motor: what the course does to whoever is standing on it.
##
## [b]The carry, and nothing else.[/b] mg-wipeout also bounced and knocked here; a trap here
## kills, and a death is the server's decision ([DrGame]), never a client's prediction. The
## carry writes the STATE and the node together: the controller starts its next tick from
## `state.position`, so a displacement applied only to the node is undone by the very next
## move — mg-smash-copter found that as a player riding a platform for one frame each tick.
func _after_tick(tick: int, state: DotFpsState) -> void:
	global_position = state.position

	if stage == null or not is_instance_valid(stage) or watching:
		return

	if state.mode == DotFpsState.Mode.GROUND and state.ground_id != 0:
		var moved := stage.carry(state.ground_id, state.position, tick)

		if moved != Vector3.ZERO:
			state.position += moved

	# Wind, in any mode: the same kind of exact displacement as the carry, so it predicts.
	var blown := stage.push_at(state.position, state.is_crouched(), tick)

	if blown != Vector3.ZERO:
		state.position += blown

	# A teleport, last: after the carry and the wind, so a floor that carried someone onto a pad
	# sends them from where they ended up. The same pure function of position on the server and
	# on a predicting client, so neither has to be told.
	# Not for a runner who has finished (they walk the end arena freely): `at_end` is replicated, so a
	# predicting client agrees with the server about it.
	if not at_end:
		var sent := stage.teleport_at(state.position, team == RUNNER_TEAM)

		if not sent.is_empty():
			_go_through(state, sent)

	global_position = state.position


## [constant DrGame.RUNNERS]. Not read from there: DrGame preloads this file.
const RUNNER_TEAM := 1


## Puts [param state] where a teleport sends it: the spot, the heading, the air (a pad is not
## ground, and `ground_id` would carry them with the floor they left), and either no velocity
## or the one they came with, per the pad's `keep`.
##
## [b]The state, in the tick[/b], and not [method place_at] from [DrGame]: that moved the server's
## copy a tick after the fact and left a predicting client to be corrected across the course.
## Here the client lands in the same tick as the server and reconciliation replays the same
## jump.
func _go_through(state: DotFpsState, sent: Array) -> void:
	var carried := state.velocity
	# The controller's own teleport, not a hand-written copy of it: it also resets the previous-state
	# blend the render interpolates from (and the position two back), so the local view does not sweep
	# across the course for a frame.
	# Not re-aiming the player's mouse on a REPLAY: a correction re-runs ticks the player has already
	# turned away from, and the sampler is the live view, so the warp's heading would snap it back to
	# where it pointed a few ticks ago. The simulated yaw is the command's on those ticks anyway.
	var live_look := controller.sampler
	if controller.is_replaying():
		controller.sampler = null
	controller.teleport(sent[0] as Vector3, float(sent[1]), 0.0)
	controller.sampler = live_look
	state.velocity = carried if bool(sent[2]) else Vector3.ZERO
	state.ground_id = 0
	warps += 1
	teleported = true


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


## Where this player's eyes are, from the simulated state rather than the drawn node.
func eye_position() -> Vector3:
	return controller.state.position + Vector3(0.0, EYE_HEIGHT, 0.0)


## The duck-typed lookup dot-weapon's player bridge asks a carrier for. Without it every shot
## leaves the player's feet pointing north; see mg-smash-copter.
func component(type_name: StringName) -> Object:
	match String(type_name):
		"DotPlayerController", "DotFpsController":
			return controller
		"DotHealth":
			return health
		"ZeeWeaponRig":
			return weapons
		_:
			return null


## Which way they are looking, as a unit vector. From yaw and pitch, never a camera.
func aim_direction() -> Vector3:
	var view := Basis.from_euler(Vector3(
		deg_to_rad(controller.state.pitch), deg_to_rad(controller.state.yaw), 0.0
	))
	return -view.z


## Puts a player somewhere, facing somewhere, with nothing carried over.
##
## [b]The state, the node and the pending command together[/b], and every one of the three
## was a separate bug in mg-smash-copter: the velocity (a player arriving still carrying a
## fall), `teleport` (the drawn view sweeping across the map for a frame) and the command
## (the motor taking the yaw back on the next tick from a command that still said north).
func place_at(at: Vector3, yaw_degrees: float) -> void:
	warps += 1
	global_position = at
	controller.teleport(at, yaw_degrees, 0.0)

	if sampler != null:
		sampler.look_at_angles(yaw_degrees, 0.0)

	var facing := DotFpsCommand.new()
	facing.yaw = yaw_degrees
	facing.pitch = 0.0
	controller.apply_command(facing)


## Back to the start of a round: nothing crossed, nothing finished, nobody watching.
func reset_progress() -> void:
	finished = false
	place = 0
	finish_seconds = 0.0
	at_end = false
	watching = false


func retune() -> void:
	if controller == null:
		return

	controller.tunables = tunables_for(config)

	if sampler != null:
		sampler.tunables = controller.tunables


func is_alive() -> bool:
	return health == null or health.alive


## Draws [member beacon] at [param at]. Client side; see mg-smash-copter's `present_beacon`.
func present_beacon(delta: float, at: Vector3, local_view: bool) -> bool:
	if not beacon or not is_alive():
		if beacon_marker != null:
			beacon_marker.queue_free()
			beacon_marker = null
		return false

	if beacon_marker == null:
		beacon_marker = DotFxBeacon.new()
		beacon_marker.name = "Beacon"
		add_child(beacon_marker)

	beacon_marker.local_view = local_view
	beacon_marker.global_position = at
	return beacon_marker.advance(delta)


## Draws this player's body for one frame at [param at]. Client side. Returns whether shown.
##
## Shown for everybody but the one the camera belongs to in first person, and anybody dead.
func present_body(own_view: bool, at: Vector3, team_colour: Color) -> bool:
	var shown := not own_view and is_alive()

	if figure == null:
		if not shown:
			return false

		figure = DrFigure.new()
		figure.name = "Figure"
		add_child(figure)

	var atlas := _atlas()

	if figure.atlas != atlas or not figure.team_colour.is_equal_approx(team_colour):
		var height := controller.tunables.stand_height \
			if controller != null and controller.tunables != null else 1.8
		figure.build(height, atlas, team_colour)

	figure.visible = shown

	if shown:
		_present_held()

	if shown and controller != null:
		var velocity := controller.state.velocity
		figure.set_motion({
			"on_floor": controller.state.mode == DotFpsState.Mode.GROUND,
			"vertical": velocity.y,
			"crouched": controller.state.crouch_fraction > 0.5,
			# The view's pitch: the upper body, the arms and the gun follow it.
			"aim": deg_to_rad(controller.state.pitch),
		})
		figure.pose(at, deg_to_rad(controller.state.yaw), Vector2(velocity.x, velocity.z).length())

	return shown


## Records a weapon the server dealt them. [param round_number] is the client's round.
func note_dealt(weapon_id: StringName, round_number: int) -> void:
	if round_number != dealt_round:
		dealt.clear()
		dealt_round = round_number

	if not dealt.has(weapon_id):
		dealt.append(weapon_id)


## Tells the figure what is in this player's hand this frame, and whether it went off.
func _present_held() -> void:
	var rig := _rig()
	var id := &""
	var switching := false
	var fired := 0
	var kind := 0

	if rig != null and rig.arsenal != null:
		var def := rig.arsenal.current_def()
		id = def.id if def != null else &""
		switching = rig.arsenal.is_switching()
		var seq := rig.fire_seq % ZeeWeaponNet.FIRE_SEQ_WRAP
		fired = ZeeWeaponNet.uses_between(_seen_fire_seq, seq) if _seen_fire_seq >= 0 else 0
		_seen_fire_seq = seq
		kind = rig.fire_kind
	elif mirrored:
		id = held_by_slot(dealt, mirror_slot)
		switching = mirror_switching
		fired = mirror_fired
		kind = mirror_fire_kind

	mirror_fired = 0
	figure.hold(id, switching)
	figure.fired(fired, kind)


## Which of [param ids] is in [param slot], or nothing. The first dealt wins a shared slot,
## which is the one the server selects at the handover.
static func held_by_slot(ids: Array[StringName], slot: int) -> StringName:
	if slot <= 0 or ids.is_empty():
		return &""

	if _slots.is_empty():
		for def in ZeeWeaponPack.weapons():
			_slots[def.id] = def.slot

	for id in ids:
		if int(_slots.get(id, -1)) == slot:
			return id

	return &""


## The rig this process simulates them with: the server's, an offline stand-in's, or the
## one a networked client builds for its own player's hands (`DrClient._arm_locally`, which
## hangs it on the player without setting [member weapons], because a client must not hand
## its rig to the simulation's lookups).
func _rig() -> ZeeWeaponRig:
	if weapons != null:
		return weapons

	return get_node_or_null(^"Weapons") as ZeeWeaponRig


func _atlas() -> String:
	var index := DrAvatars.skin_index(avatar)

	if index < 0 or index >= DrFigure.ATLASES.size():
		index = DrAvatars.stock_index(player_id)

	return str(DrFigure.ATLASES[index])


func describe() -> Dictionary:
	return {
		"id": String(player_id),
		"side": team,
		"alive": is_alive(),
		"health": health.health if health != null else 0.0,
		"finished": "#%d in %.1f s" % [place, finish_seconds] if finished else "no",
		"at_end": at_end,
		"watching": watching,
		"armed": weapons != null,
		"blinded": blinded,
		"beacon": beacon,
		"avatar": avatar.digest() if avatar != null else "stock",
	}
