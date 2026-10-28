extends Node3D

## The stand-in runners' and activators' perception and path helpers, split out of `dr_game.gd` to keep it under the size budget. No `class_name`; the world extends this.

const DrConfig := preload("dr_config.gd")
const DrCourse := preload("dr_course.gd")
const DrPlayer := preload("dr_player.gd")

## The preset the bots' numbers are taken relative to, so medium plays as before presets.
## Fewest walkway points a round's first step may skip, counting from the spawn (point -1).
const WALKWAY_SKIP_MIN := 8

@export var config: DrConfig = null

@export_range(1, 240, 1) var tick_rate: int = 64

var stage: DrCourse = null

var physics: DotPhysicsLayout = null

## player id -> DrPlayer.
var players: Dictionary = {}

## player id -> side: [constant RUNNERS] or [constant ACTIVATORS].
var sides: Dictionary = {}

var round_number: int = 0

var _tick: int = 0

## Stand-in activators: player id -> the walkway point they last reached (-1: still at the spawn).
var _bot_walk: Dictionary = {}

var _bot_hands: Dictionary = {}

## Whether there is something to stand on under [param point], within a metre and a half down.
## A ray through the world layer, so a trapdoor that has opened is not a floor.
func _floor_at(point: Vector3) -> bool:
	var world := get_world_3d()

	if world == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(point + Vector3(0.0, 0.5, 0.0), point + Vector3(0.0, -1.5, 0.0))
	query.collision_mask = physics.layer_mask(&"world") if physics != null else 1
	return not world.direct_space_state.intersect_ray(query).is_empty()


## Steers a bot in the air so it lands on [param target] rather than past it. The overshoot is
## measured along the velocity, not toward the target (which reads zero when nearly above it); the brake
## is the constant deceleration `2·over / t²` that removes it in the time left.
func _bot_land_on(player: DrPlayer, command: DotFpsCommand, target: Vector3) -> void:
	var state := player.controller.state
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)

	var to_target := Vector2(target.x - state.position.x, target.z - state.position.z)

	if flat.length() < 0.3 or to_target.length() > 7.0:
		return

	# Not going at the target: a drift, not a jump that can carry past it, and braking along
	# the drift zeroed the wish toward it. A standing jump up a 0.94 m riser drifted sideways
	# at 0.4 m/s, had its forward push taken away every time, and bounced off the face forever.
	if Vector2(flat.x, flat.z).normalized().dot(to_target.normalized()) < 0.5:
		return

	var g := config.gravity
	var rise := target.y - state.position.y
	var root := state.velocity.y * state.velocity.y - 2.0 * g * rise

	if root < 0.0:
		return

	var falls_in := (state.velocity.y + sqrt(root)) / g

	if falls_in <= 0.02:
		command.move = Vector2.ZERO
		return

	var heading := flat.normalized()
	var landing := state.position + flat * falls_in
	var over := Vector3(landing.x - target.x, 0.0, landing.z - target.z).dot(heading)

	command.yaw = rad_to_deg(atan2(-heading.x, -heading.z))

	if over <= 0.2:
		# Nothing in: no wish adds nothing to a jump already at speed.
		command.move = Vector2.ZERO
		return

	# The motor takes `air_accelerate · wish · run_speed` off per second with the wish fully
	# against it; the brake wanted is `2·over / t²`.
	var wanted := 2.0 * over / (falls_in * falls_in)
	var full := config.air_accelerate * config.run_speed
	command.move = Vector2(0.0, -clampf(wanted / maxf(full, 0.01), 0.05, 1.0))


## The walkway point already reached at round start: the nearest to [param stop] that is close and in
## the open. A tour revisits its own corridors, so without it a late activator walks from the start.
func _walkway_shortcut(player: DrPlayer, points: Array, here: int, stop: int) -> int:
	var at := player.controller.state.position
	var best := here
	var best_left := absi(stop - here)

	for i in range(points.size()):
		var left := absi(stop - i)

		# Forward only: a walk back along the tour meets drops and corners the rays do not.
		if left >= best_left or i == here or i > stop:
			continue

		var point: Vector3 = (points[i] as Dictionary)["at"]

		if Vector2(point.x - at.x, point.z - at.z).length() > 8.0 or absf(point.y - at.y) > 1.0:
			continue

		# And the way on from there must be open too, or the activator is counted past a corner
		# it still has to turn.
		var onward: Vector3 = (points[clampi(i + signi(stop - i), 0, points.size() - 1)] as Dictionary)["at"]

		if _walkway_clear(at, point) and _walkway_clear(at, onward) and _walkway_floored(at, onward):
			best = i
			best_left = left

	# Only a long skip is worth the risk of a corner the ray cannot see; a few points are walked.
	if best_left > absi(stop - here) - WALKWAY_SKIP_MIN:
		return here

	return best


## Whether there is floor under the whole of the straight line between two points.
func _walkway_floored(from: Vector3, to: Vector3) -> bool:
	for step in range(1, 9):
		var sample := from.lerp(to, float(step) / 8.0)
		sample.y = lerpf(from.y, to.y, float(step) / 8.0)

		if not _floor_at(sample):
			return false

	return true


## Whether nothing solid stands between two points of the walkway at waist height.
func _walkway_clear(from: Vector3, to: Vector3) -> bool:
	var world := get_world_3d()

	if world == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(from + Vector3(0.0, 0.7, 0.0), to + Vector3(0.0, 0.7, 0.0))
	query.collision_mask = physics.layer_mask(&"world") if physics != null else 1
	return world.direct_space_state.intersect_ray(query).is_empty()


## How far [param player] has to walk to be at trap [param index]'s button: along the walkway
## when the course has one, else in a straight line.
func _bot_walk_distance(player: DrPlayer, index: int) -> float:
	var at := player.controller.state.position
	var button := stage.button_point(index)
	var points := stage.walkway()
	var stop := stage.walkway_stop(index) if not points.is_empty() else -1

	if stop < 0:
		return Vector2(button.x - at.x, button.z - at.z).length()

	var here: int = int(_bot_walk.get(player.player_id, -1))

	if here < 0:
		here = _walkway_shortcut(player, points, here, stop)

	if here == stop:
		return Vector2(button.x - at.x, button.z - at.z).length()

	var step := 1 if here < stop else -1
	var first: Vector3 = (points[here + step] as Dictionary)["at"]
	var total := Vector2(first.x - at.x, first.z - at.z).length()

	for i in range(here + step, stop, step):
		var from: Vector3 = (points[i] as Dictionary)["at"]
		var to: Vector3 = (points[i + step] as Dictionary)["at"]
		total += Vector2(to.x - from.x, to.z - from.z).length()

	return total


func _nearest_enemy(player: DrPlayer) -> DrPlayer:
	var best: DrPlayer = null
	var closest := INF

	for id: StringName in players:
		var other: DrPlayer = players[id]

		if other == player or not other.is_alive() or other.watching or not other.at_end:
			continue

		if int(sides.get(id, 0)) == player.team:
			continue

		var distance := other.controller.state.position.distance_to(player.controller.state.position)

		if distance < closest:
			closest = distance
			best = other

	return best


## Aims a stand-in at [param target] with dot-bot's [DotBotAim] on `bot_difficulty` and says whether
## it fires this tick. Seeded per bot and per round so an empty server does not replay one fight.
func _aim_bot(player: DrPlayer, command: DotFpsCommand, target: DrPlayer) -> void:
	var aim: DotBotAim = _bot_hands.get(player.player_id)

	if aim == null:
		aim = DotBotAim.new(round_number * 8192 + int(player.entity_id % 8192), DotBotSettings.of(self))
		aim.view_from(command.yaw, command.pitch)
		_bot_hands[player.player_id] = aim

	var eye := player.eye_position()
	var at := target.controller.state.position + Vector3(0.0, 1.25, 0.0)
	var now := float(_tick) / float(maxi(tick_rate, 1))
	var _new := aim.engage(target.entity_id, eye, at, now)
	var view := aim.track(eye, at, target.controller.state.velocity, now, 1.0 / float(maxi(tick_rate, 1)))
	command.yaw = view.x
	command.pitch = clampf(view.y, -89.0, 89.0)
	var fire := aim.trigger(now, eye.distance_to(at))
	if fire:
		aim.note_shot(eye, at, now)
	command.set_button(DotFpsCommand.BUTTON_USER_0, fire)


# Reacting
