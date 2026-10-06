extends Node3D

const DrCatalogue := preload("dr_catalogue.gd")
const DrConfig := preload("dr_config.gd")
const DrCourse := preload("dr_course.gd")
const DrCourseDoc := preload("dr_course_doc.gd")
const DrPlayer := preload("dr_player.gd")
const DrProgress := preload("dr_progress.gd")
const DrRules := preload("dr_rules.gd")
const DrSpectate := preload("dr_spectate.gd")

## The simulation. Headless, authoritative, and the only thing that decides anything.
##
## [b]A round is a corridor of traps and the people pressing them.[/b] Most players are
## runners: they start behind a gate and run one long course to its end. One or more are
## activators, drawn fresh each round, standing in a corridor of their own beside the course
## with a button for every trap. A runner who reaches the end is handed a weapon in the end
## arena, and the first one there calls the activators down to meet them. Every runner dead is
## the activators' round; every activator dead is the runners'; the clock is the activators'
## unless the server says otherwise.
##
## [b]Nothing comes back.[/b] There is no respawn and no checkpoint: a trap that catches you
## ends your round, which is what makes a press worth anything. Somebody out watches.
##
## [b]What it owns and what it borrows.[/b] The round, the sides and the scoreboard are
## dot-match's (decided through [DrRules]); health and damage are dot-combat's; the weapons are
## zee-dot-weapons'. The course, the traps and who pressed which are [DrCourse], and are this
## game's own.

const CHANNEL := "dr.game"

## Where this world publishes itself, so a module can find it. A registry name and not an
## autoload: a server and a client in one process are two of these.
const SERVICE := &"dr_game"

## Snapshots a second. Thirty, like mg-wipeout: what a player reads continuously here is other
## people on floors that move under them.
const NET_SNAPSHOT_RATE := 30

## How far a position may be from the origin, in metres, on the wire. Both ends read it here.
const NET_WORLD_EXTENT := 512.0

## The two sides. Fixed ids, because the whole game is about which of the two somebody is.
const RUNNERS := 1
const ACTIVATORS := 2

const TEAM_COLOURS: Array[Color] = [
	Color(0.32, 0.58, 0.90),
	Color(0.88, 0.30, 0.26),
]

const TEAM_NAMES: Array[String] = ["Runners", "Activators"]

## Which part of the round it is.
enum Phase {
	## Between rounds, or waiting for enough people to start one.
	IDLE,
	## The runners behind the gate, the activators finding their feet.
	COUNTDOWN,
	## The gate is down and the course is open.
	RUN,
	## Somebody reached the end and the activators have been called to it. The traps still
	## work for whoever is still on the course — but there is nobody left at the buttons.
	SHOWDOWN,
}

const DIED_TRAP := &"trap"
const DIED_PIT := &"pit"
const DIED_FELL := &"fell"
const DIED_SHOT := &"shot"

## Seconds after being in a running trap's reach that a fall or a pit is still that trap's.
##
## [b]A trapdoor does not kill anybody; the spikes under it do.[/b] Without this every death in
## a pit is the course's, and the activator who opened the floor is credited with nothing —
## which reads to them as a press that did not work.
const CREDIT_SECONDS := 4.0

signal player_added(player_id: StringName)
signal player_removed(player_id: StringName)

## A round began, on [param course_id].
signal round_began(number: int, course_id: StringName)

## The stage is about to be taken down and rebuilt. Before, for the bridge's sake.
signal world_clearing()

## The stage has just been rebuilt. The bridge answers by sending the document.
signal world_rebuilt()

## A round ended. [param winner] is a side (0 for a draw); [param winner_name] says why.
signal round_over(number: int, winner: int, winner_name: String)

signal phase_changed(phase: int)

## Somebody changed sides: the draw at the top of a round, or a joiner put on one.
signal side_changed(player_id: StringName, side: int)

signal player_died(player_id: StringName, by: StringName, why: StringName)

## An activator pressed trap [param index]'s button on [param tick].
signal trap_fired(index: int, tick: int, by: StringName)

## Somebody pressed a button that did nothing, and why. Told to them alone.
signal button_refused(player_id: StringName, why: String)

## A runner crossed the finish, [param place] first, in [param seconds].
signal player_finished(player_id: StringName, place: int, seconds: float)

signal achievement_earned(player_id: StringName, title: String, points: int)

## Somebody was handed a weapon.
signal player_armed(player_id: StringName, weapon_id: StringName)

@export var config: DrConfig = null

## Whether this instance decides anything. A client sets this false.
@export var authoritative: bool = true

@export_range(1, 240, 1) var tick_rate: int = 64

## Whether something else drives the tick: the bridge, on both ends.
@export var external_tick: bool = false

## Whether this world publishes itself under [constant SERVICE].
@export var register_service: bool = true

## Whether the stage draws its sky and its void. A client sets it.
@export var draw_world: bool = false

var stage: DrCourse = null
var catalogue: DrCatalogue = null
var combat: DotCombatManager = null
var match_node: DotMatch = null
var random: DotRandomManager = null
var physics: DotPhysicsLayout = null
var effects: DotFxManager = null
var spectate: DrSpectate = null
var progress: DrProgress = null

## player id -> DrPlayer.
var players: Dictionary = {}

## player id -> side: [constant RUNNERS] or [constant ACTIVATORS].
var sides: Dictionary = {}

var round_number: int = 0

## Seconds into the current phase. Simulated, never a wall clock.
var phase_elapsed: float = 0.0

## Seconds since the gate dropped. What a finish time is, and the round clock.
var run_elapsed: float = 0.0

var phase: int = Phase.IDLE

## The course this round is run on.
var course_doc: Dictionary = {}

var entities := DotEntityTable.new()

## What the server last said about numbers a client cannot count. Negative is "count it".
var remote_runners: int = -1
var remote_activators: int = -1
var remote_playable: bool = false

## trap index -> who pressed it last. Who a trap's deaths are credited to.
var pressed_by: Dictionary = {}

var _tick: int = 0
var _round_seed: int = 0
var _finish_count: int = 0

## Whether the course standing now has not been run yet: the warmup's, until round one.
var _course_unplayed: bool = false

## Whether the round has been decided, and who won. What [DrRules] reads.
var _decided: bool = false
var _winner: int = 0
var _winner_name: String = ""

## Who was an activator last round, so the draw can pass them over.
var _last_activators: Array[StringName] = []

## player id -> `[trap index, tick]`: the last running trap whose reach they were in.
var _credit: Dictionary = {}

## player id -> tick they become hurtable again, after arriving in the end arena.
var _grace: Dictionary = {}

## Bots: player id -> the route point they are heading for, their aim error, the tick a
## runner entered the trap they are watching, and `[position, tick]` a second ago.
var _bot_route: Dictionary = {}
var _bot_hands: Dictionary = {}
var _bot_watch: Dictionary = {}
var _bot_stuck: Dictionary = {}

## Bots: player id -> the middle of what a bot just landed on, while it stops and steps back
## to it before the next jump.
var _bot_settle: Dictionary = {}


func _ready() -> void:
	if config == null:
		config = DrConfig.new()

	var valid := config.validate()

	if not valid.ok:
		# FATAL is reserved for "the process cannot continue", and a configuration that
		# contradicts itself is not that: say so loudly and refuse to run a round.
		DotLog.error(CHANNEL, "the configuration is not usable", {"why": valid.error.message})
		return

	_round_seed = config.seed_value

	_build_physics()
	_apply_gravity()
	_build_random()
	_build_stage()
	_build_combat()
	_build_effects()
	_build_match()
	_build_spectate()
	_build_progress()

	if authoritative:
		catalogue = DrCatalogue.new()
		var _loaded := catalogue.load_from(config.course_directory)
		# Laid out now, not on the first round: dot-match runs a warmup first, and an empty
		# world through the warmup is indistinguishable from a map that failed to load.
		_lay_out_course()

	if register_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(CHANNEL, "world ready", config.describe())


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

## The named collision layers: the world and the players.
func _build_physics() -> void:
	physics = DotPhysicsLayout.custom(&"deathrun", [&"world", &"player"])

	for layer in physics.layers:
		match layer.id:
			&"player":
				# Not other players. Two runners shoving on a ledge is a race decided by who
				# walked into whom, drawn in the past on every client — and on a course where a
				# shove is a death, it would be the deadliest thing on it.
				layer.collides_with = [&"world"]
			_:
				layer.collides_with = [&"player"]

	var built := physics.build()

	if not built.ok:
		DotLog.error(CHANNEL, "the collision layout would not build", {"why": built.error.message})
		physics = null


## The gravity the course is tuned against, on this world's own physics SPACE. A project
## setting does not travel with a delivered pack; see [member DrConfig.gravity].
func _apply_gravity() -> void:
	var world := get_world_3d()

	if world == null:
		DotLog.warn(CHANNEL, "no world to set gravity on", {})
		return

	PhysicsServer3D.area_set_param(world.space, PhysicsServer3D.AREA_PARAM_GRAVITY, config.gravity)


func _build_random() -> void:
	random = DotRandomManager.new()
	random.name = "Random"
	# Off: a registry name is process-wide, and two worlds in one process is every suite.
	random.register_as_service = false
	add_child(random)
	var _started := random.setup()
	random.reseed(_round_seed)


func _build_stage() -> void:
	stage = DrCourse.new()
	stage.name = "Stage"
	stage.physics = physics
	stage.tick_rate = tick_rate
	stage.draw_world = draw_world
	add_child(stage)


func _build_combat() -> void:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = authoritative
	combat.register_service = false

	var rules := DotDamageRules.new()
	rules.friendly_fire = false
	rules.self_damage = true
	rules.hit_groups = true
	combat.rules = rules

	# Lag compensation OFF here and turned on by the bridge with the callables that make it
	# real — mg-smash-copter's finding: left on, a delivered server logged "no rewind function"
	# at every boot about a server where it works.
	var settings := DotCombatConfig.new()
	settings.lag_compensation = false
	combat.config = settings

	# A trace, or every shot goes through the arena's walls. Before `setup`, which warns.
	var trace := DotTracePhysics.for_world(get_world_3d())

	if physics != null:
		trace.collision_mask = physics.layer_mask(&"world")

	combat.trace = trace

	# Which side an entity is on, or friendly fire is ON between two runners.
	combat.resolver = DotDamageResolver.with_rules(rules)
	combat.resolver.hit_groups = DotHitGroup.defaults()
	combat.resolver.team_of = func(entity_id: int) -> int:
		return team_of(entities.key_for_id(entity_id))

	# `add_child` IS the setup; calling it again doubled every boot line. See mg-smash-copter.
	add_child(combat)


## A flash for the gate and a shake for a trap going off near you. Client side.
func _build_effects() -> void:
	if authoritative and not draw_world:
		return

	var catalogue_fx := DotFxCatalogue.new()

	var trap := DotFxDef.new()
	trap.id = &"trap"
	trap.kind = DotFxDef.Kind.SHAKE
	trap.shake_trauma = 0.4
	trap.max_distance = 14.0
	catalogue_fx.add(trap)

	var go := DotFxDef.new()
	go.id = &"go"
	go.kind = DotFxDef.Kind.SCREEN
	go.flash_peak = 0.22
	go.flash_colour = Color(0.98, 0.86, 0.35, 1.0)
	go.flash_decay_ms = 380
	catalogue_fx.add(go)

	effects = DotFxManager.new()
	effects.name = "Effects"
	effects.catalogue = catalogue_fx
	effects.config = DotFxConfig.new()
	effects.register_as_service = false
	add_child(effects)

	DotLog.result(CHANNEL, "the effects layer", effects.setup())


func _build_match() -> void:
	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.register_service = false

	var match_config := DotMatchConfig.new()
	match_config.tick_rate = tick_rate
	match_config.auto_start = false
	match_config.log_transitions = false
	# Off: the sides are drawn by this game every round (see [method _draw_sides]), and a
	# rebalance after the draw would move the activator back among the runners.
	match_config.balance_between_rounds = false
	match_node.config = match_config

	var rules: DotMatchRules = DrRules.make()
	rules.intermission_sec = config.intermission_seconds
	rules.warmup_sec = config.warmup_seconds
	rules.countdown_sec = 0.0
	rules.team_based = true
	# Two: an activator and a runner is the smallest round that is a round.
	rules.min_players = 2
	rules.set(&"decision_fn", _decision)
	rules.time_limit_sec = config.countdown_seconds + config.round_seconds + 60.0
	match_node.rules = rules

	# Scoped to the match node, which finds nothing: this game places its own players, and an
	# unset `spawns_ref` walks the whole scene and finds another world's.
	match_node.spawns_ref = DotNodeRef.of_path(^".")

	add_child(match_node)

	match_node.round_started.connect(_on_round_started)
	match_node.round_ended.connect(_on_round_ended)

	var teams: Array[DotTeam] = [
		DotTeam.make(RUNNERS, TEAM_NAMES[0], TEAM_COLOURS[0]),
		DotTeam.make(ACTIVATORS, TEAM_NAMES[1], TEAM_COLOURS[1]),
	]

	match_node.teams.teams = teams
	match_node.teams.force_balance = false
	match_node.teams.allow_choice = false
	# Off: the sides are this game's to draw, and dot-match's default difference of one refused
	# a ninth runner against one activator.
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


func _decision() -> Dictionary:
	return {"decided": _decided, "winner": _winner}


func _build_spectate() -> void:
	spectate = DrSpectate.new()
	spectate.name = "Spectate"
	spectate.players = players
	spectate.sides = sides
	spectate.phase_fn = func() -> int: return phase
	spectate.in_showdown_fn = func(p: int) -> bool: return p == Phase.SHOWDOWN
	add_child(spectate)

	var ready_now := spectate.setup(authoritative, tick_rate, config.spectate_camera)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "spectating is off", {"why": ready_now.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = DrProgress.new()
	progress.name = "Progress"
	progress.players = players
	progress.sides = sides
	add_child(progress)

	var ready_now := progress.setup(config.progress_directory, config.report_progress)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "progress is off", {"why": ready_now.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null
		return

	progress.earned.connect(func(id: StringName, title: String, points: int) -> void:
		achievement_earned.emit(id, title, points)
	)


func _refresh_overviews() -> void:
	if spectate == null or stage == null or stage.doc.is_empty():
		return

	var box := stage.bounds()
	var centre := box.get_center()
	var reach := maxf(box.size.length() * 0.5, 12.0)
	var eye := centre + Vector3(reach * 0.55, reach * 0.5 + 10.0, reach * 0.2)
	var field := Transform3D(Basis.IDENTITY, eye).looking_at(centre, Vector3.UP)

	# The arena's camera: above the runners' end, looking at the activators'.
	var end: Dictionary = stage.doc["end"]
	var from: Vector3 = (end["runners"] as Dictionary)["at"]
	var to: Vector3 = (end["activators"] as Dictionary)["at"]
	var middle := from.lerp(to, 0.5)
	var arena := Transform3D(Basis.IDENTITY, from + (from - to).normalized() * 3.0 + Vector3(0.0, 9.0, 0.0)) \
		.looking_at(middle, Vector3.UP)
	spectate.set_overviews(field, arena)


# --- Players ----------------------------------------------------------------

## Puts somebody in the world. [param wanted_side] is a side, or 0 to be placed.
func add_player(
	player_id: StringName,
	display_name: String,
	wanted_side: int = 0,
	samples_input: bool = false
) -> DrPlayer:
	if players.has(player_id):
		return players[player_id]

	var side := ACTIVATORS if wanted_side == ACTIVATORS else RUNNERS

	var player := DrPlayer.new()
	player.name = "Player_%s" % String(player_id)
	player.player_id = player_id
	player.display_name = display_name
	player.samples_input = samples_input
	player.tick_rate = tick_rate
	player.config = config
	player.stage = stage
	player.team = side
	add_child(player)

	if physics != null:
		var applied := physics.apply_to(player, &"player")

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not be put on its collision layer", {
				"why": applied.error.message,
			})

		# And the motor's own mask, which defaults to 1. A controller left on the default
		# sweeps against layer one only, which is a player falling through the course.
		player.controller.tunables.collision_mask = physics.collision_mask(&"player")

	var opened := entities.open(
		DotEntity.KIND_PLAYER, player, &"", player_id, float(_tick) / float(maxi(tick_rate, 1))
	)

	if not opened.ok:
		DotLog.error(CHANNEL, "could not open an entity for a player", {
			"id": String(player_id), "why": opened.error.message,
		})

	player.entity_id = (opened.value as DotEntityHandle).id if opened.ok else 0

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = config.player_health
	health.health = config.player_health
	player.add_child(health)
	player.health = health

	if combat != null:
		combat.register_health(player.entity_id, health)
		_give_hitboxes(player)

	health.died.connect(func(damage: DotDamage) -> void: _on_player_died(player, damage))

	players[player_id] = player
	sides[player_id] = side

	if match_node != null:
		var seated := match_node.add_player(String(player_id), display_name, _tick, side)

		if not seated.ok:
			DotLog.error(CHANNEL, "dot-match refused a player", {
				"id": String(player_id), "side": side, "why": seated.error.message,
			})

	# Placed NOW, not only at the top of a round: a joiner left at the origin is a joiner
	# falling, and mg-smash-copter's version of that ended rounds.
	place_one(player)

	DotLog.debug(CHANNEL, "player joined", {"id": String(player_id), "side": side})

	# Last, after the health and the side: the bridge answers this by replicating the player.
	player_added.emit(player_id)
	return player


## Somewhere on a player a shot can land. Without it nobody can be shot and nothing says so.
func _give_hitboxes(player: DrPlayer) -> void:
	var boxes := DotHitboxSet.new()
	boxes.name = "Hitboxes"
	boxes.owner_ref = DotNodeRef.of_path(^"..")
	player.add_child(boxes)

	var body := DotHitbox.new()
	body.name = "Chest"
	body.group = DotHitGroup.CHEST
	body.shape = DotHitbox.Shape.CAPSULE
	body.radius = 0.34
	body.height = 1.25
	body.position = Vector3(0.0, 0.78, 0.0)
	body.damage_scale = 1.0
	body.precedence = 0
	boxes.add_child(body)

	var head := DotHitbox.new()
	head.name = "Head"
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.19
	head.position = Vector3(0.0, DrPlayer.EYE_HEIGHT + 0.06, 0.0)
	head.damage_scale = 2.2
	head.precedence = 10
	boxes.add_child(head)

	boxes.refresh()
	boxes.register_with(combat, player.entity_id)


## Puts one player somewhere they can be, for the phase it is.
##
## [b]A joiner in the middle of a round watches it.[/b] Starting them at the start behind
## everybody would be a runner the activator has already spent every trap on, and putting
## them in the activators' corridor would hand a stranger the buttons.
func place_one(player: DrPlayer) -> void:
	if stage == null or stage.doc.is_empty():
		return

	var spot := stage.start_spot(players.size() - 1, 1000)

	if int(sides.get(player.player_id, RUNNERS)) == ACTIVATORS:
		spot = stage.activator_spot(0, 1000)

	player.place_at(spot[0], spot[1])

	if authoritative and (phase == Phase.RUN or phase == Phase.SHOWDOWN):
		_bench(player)
	elif spectate != null:
		spectate.on_spawned(player.player_id)


## Sits somebody out for the rest of the round: watching, unhurtable, not counted.
func _bench(player: DrPlayer) -> void:
	player.watching = true

	if player.health != null:
		player.health.invulnerable = true

	if spectate != null:
		spectate.on_died(player.player_id, &"", false, player.controller.state.position,
			stage.kill_height() + 8.0, _tick)


func remove_player(player_id: StringName) -> void:
	if not players.has(player_id):
		return

	var player: DrPlayer = players[player_id]

	# Before the node goes: dot-combat keyed a health on this entity, and a stale record has
	# no symptom until the process runs out of memory.
	if combat != null and is_instance_valid(combat) and player.entity_id != 0:
		combat.forget(player.entity_id)
		var _closed := entities.close(player.entity_id, DotEntityTable.REASON_OWNER_LEFT)

	if match_node != null:
		match_node.remove_player(String(player_id))

	players.erase(player_id)
	sides.erase(player_id)
	_last_activators.erase(player_id)

	for table in [_bot_route, _bot_hands, _bot_watch, _bot_stuck, _bot_settle, _credit, _grace]:
		(table as Dictionary).erase(player_id)

	player.queue_free()

	if spectate != null:
		spectate.on_left(player_id)

	if progress != null:
		progress.leave(player_id)

	player_removed.emit(player_id)


func team_of(player_id: StringName) -> int:
	return int(sides.get(player_id, 0))


func side_name(side: int) -> String:
	if side == RUNNERS or side == ACTIVATORS:
		return TEAM_NAMES[side - 1]

	return "nobody"


func side_colour(side: int) -> Color:
	if side == RUNNERS or side == ACTIVATORS:
		return TEAM_COLOURS[side - 1]

	return Color(0.7, 0.7, 0.7)


func players_on(side: int) -> Array[DrPlayer]:
	var out: Array[DrPlayer] = []

	for id: StringName in players:
		if int(sides.get(id, 0)) == side:
			out.append(players[id])

	return out


## How many of a side are up and in the round.
func alive_on(side: int) -> int:
	if not authoritative:
		if side == RUNNERS and remote_runners >= 0:
			return remote_runners
		if side == ACTIVATORS and remote_activators >= 0:
			return remote_activators

	var total := 0

	for player in players_on(side):
		if player.is_alive() and not player.watching:
			total += 1

	return total


func finished_count() -> int:
	return _finish_count


## Whether there are enough people for a round. Two, of anybody.
func sides_are_playable() -> bool:
	if not authoritative:
		return remote_playable

	return players.size() >= 2


# --- The round --------------------------------------------------------------

func start() -> void:
	if not authoritative:
		return

	# Built again here, not only in `_ready`: on a server nothing is listening when the world
	# opens — the module builds the bridge that answers `world_rebuilt` — and a course built
	# before it is a course no client is ever sent. The SAME course, unless it is no longer one
	# this server plays (a delivered server's courses arrive after the world opened).
	var id := StringName(str(course_doc.get("id", "")))

	if not course_doc.is_empty() and catalogue != null \
			and catalogue.playable_courses(config.course_ids).has(id):
		var _rebuilt := build_stage(course_doc)
		_place_everybody()
	else:
		_lay_out_course()

	match_node.start(_tick)


func _on_round_started(number: int) -> void:
	round_number = number
	_round_seed = config.seed_value + number * 7919
	random.reseed(_round_seed)

	# The course the warmup showed, for the first round — not built again, only put back: every
	# client already has it, and a second STAGE for the same document is a second build on every
	# one of them for nothing. The next course after that.
	if _course_unplayed and not course_doc.is_empty() and stage.id() == StringName(str(course_doc["id"])):
		stage.reset_traps()
	else:
		_lay_out_course()

	_course_unplayed = false
	_decided = false
	_winner = 0
	_winner_name = ""
	_finish_count = 0
	run_elapsed = 0.0
	pressed_by.clear()
	_credit.clear()
	_grace.clear()
	_bot_watch.clear()

	_draw_sides()
	_place_everybody()

	if progress != null:
		progress.on_round_began()

	_set_phase(Phase.COUNTDOWN)
	round_began.emit(number, stage.id())

	DotLog.info(CHANNEL, "round began", {
		"number": number, "course": String(stage.id()), "seed": _round_seed,
		"players": players.size(), "activators": ", ".join(_names(players_on(ACTIVATORS))),
	})


func _on_round_ended(number: int, winner: int, _outcome: int) -> void:
	_set_phase(Phase.IDLE)

	# The clock dot-match itself called, past every clock this game keeps: a backstop that
	# should never be what ends a round, and is said so when it is.
	if not _decided:
		_winner_name = "the round ran out"

	if progress != null:
		progress.on_round_over(winner)

	round_over.emit(number, winner, _winner_name)
	DotLog.info(CHANNEL, "round over", {"number": number, "winner": _winner_name})


## Who presses the buttons this round.
##
## [b]Drawn, seeded, and never the same person twice running when there is anybody else.[/b]
## A rotation would be fairer on paper and is gamed in practice — the order is learned and
## somebody leaves and rejoins to move up it — while a draw that repeats is read as the server
## playing favourites. So: everybody who was not an activator last round goes in the hat, and
## the hat is the round's own seed.
func _draw_sides() -> void:
	var ids: Array = players.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var wanted := config.activators_for(ids.size())
	var hat: Array = []

	for id: StringName in ids:
		if config.activator_may_repeat or not _last_activators.has(id):
			hat.append(id)

	# Not enough fresh names: everybody goes back in, rather than a round short of activators.
	if hat.size() < wanted:
		hat = ids.duplicate()

	var stream := random.stream(&"activators")
	_shuffle(hat, stream)

	# The players' own choices, after the shuffle so each group stays in drawn order:
	# volunteers first, the undecided next, and anybody who asked to run last — drawn only if
	# the round would otherwise be short of an activator, because there must always be one.
	if config.allow_side_choice:
		var keen: Array = []
		var either: Array = []
		var reluctant: Array = []
		for id: StringName in hat:
			match (players[id] as DrPlayer).side_wish:
				ACTIVATORS:
					keen.append(id)
				RUNNERS:
					reluctant.append(id)
				_:
					either.append(id)
		hat = keen + either + reluctant

	var drawn: Array[StringName] = []

	for index in range(mini(wanted, hat.size())):
		drawn.append(hat[index])

	_last_activators = drawn

	for id: StringName in ids:
		_set_side(id, ACTIVATORS if drawn.has(id) else RUNNERS)


## A player's choice of side, from chat. Server side. Takes effect at the next draw.
func wish_side(id: StringName, side: int) -> void:
	var player: DrPlayer = players.get(id)
	if player != null:
		player.side_wish = side if side == RUNNERS or side == ACTIVATORS else 0


func _set_side(id: StringName, side: int) -> void:
	var player: DrPlayer = players.get(id)

	if player == null:
		return

	var was := int(sides.get(id, 0))
	sides[id] = side
	player.team = side

	if match_node != null and was != side:
		var _moved := match_node.switch_team(String(id), side, _tick)

	if was != side:
		side_changed.emit(id, side)


static func _names(of: Array[DrPlayer]) -> PackedStringArray:
	var out := PackedStringArray()

	for player in of:
		out.append(player.display_name)

	return out


## The next course, built.
func _lay_out_course() -> void:
	if catalogue == null:
		return

	var doc := catalogue.next_course(
		config.course_ids, config.shuffle_courses, random.stream(&"course"),
		StringName(str(course_doc.get("id", "")))
	)

	build_stage(doc)
	_place_everybody()
	_course_unplayed = true


## Builds [param doc] as the stage. What the server does at a round start, and what a client
## does when it is sent one.
func build_stage(doc: Dictionary) -> DotResult:
	world_clearing.emit()

	var built := stage.build(doc)

	if not built.ok:
		DotLog.error(CHANNEL, "a course would not build", {
			"id": str(doc.get("id", "?")), "why": built.error.message,
		})
		return built

	course_doc = stage.doc
	stage.gate_closed = phase == Phase.COUNTDOWN or phase == Phase.IDLE
	_refresh_overviews()

	# Last, once it is all standing: the bridge answers this by sending the document.
	world_rebuilt.emit()
	return built


## Everybody to where their side starts, whole, holding nothing.
func _place_everybody() -> void:
	var ids := players.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var runners := 0
	var activators := 0
	var runner_count := 0

	for id: StringName in ids:
		if int(sides.get(id, RUNNERS)) == RUNNERS:
			runner_count += 1

	for id: StringName in ids:
		var player: DrPlayer = players[id]
		player.reset_progress()
		_disarm(player)

		if player.health != null:
			player.health.max_health = config.player_health
			player.health.health = config.player_health
			player.health.alive = true
			player.health.invulnerable = false

		var spot: Array

		if int(sides.get(id, RUNNERS)) == ACTIVATORS:
			spot = stage.activator_spot(activators, maxi(players.size() - runner_count, 1))
			activators += 1
		else:
			spot = stage.start_spot(runners, maxi(runner_count, 1))
			runners += 1

		player.place_at(spot[0], spot[1])
		_bot_route[player.player_id] = 0

		if spectate != null:
			spectate.on_spawned(player.player_id)


func _set_phase(to: int) -> void:
	if phase == to:
		return

	phase = to
	phase_elapsed = 0.0

	if stage != null:
		stage.gate_closed = to == Phase.COUNTDOWN or to == Phase.IDLE

	phase_changed.emit(to)
	DotLog.debug(CHANNEL, "the round changed phase", {"phase": Phase.keys()[to]})


## The clock, and every decision it makes.
func _advance_phase(delta: float) -> void:
	if phase == Phase.IDLE:
		return

	phase_elapsed += delta

	match phase:
		Phase.COUNTDOWN:
			if phase_elapsed >= config.countdown_seconds:
				run_elapsed = 0.0
				_set_phase(Phase.RUN)
		Phase.RUN, Phase.SHOWDOWN:
			run_elapsed += delta
			_check_round()


## The round's own clock: the document's, under the server's ceiling.
func round_limit() -> float:
	var asked := float(course_doc.get("round_seconds", 0.0))
	return minf(asked, config.round_seconds) if asked > 0.0 else config.round_seconds


## Last side standing, or the clock.
func _check_round() -> void:
	var runners := alive_on(RUNNERS)
	var activators := alive_on(ACTIVATORS)

	if runners == 0 and activators == 0:
		_decide(0, "nobody is left")
	elif runners == 0:
		_decide(ACTIVATORS, "the traps got everybody")
	elif activators == 0:
		_decide(RUNNERS, "the runners got the activator" if players_on(ACTIVATORS).size() <= 1 \
			else "the runners got the activators")
	elif run_elapsed >= round_limit():
		match config.timeout_winner:
			RUNNERS:
				_decide(RUNNERS, "time: the runners held out")
			ACTIVATORS:
				_decide(ACTIVATORS, "time: nobody got to the end")
			_:
				_decide(0, "time")


func _decide(winner: int, why: String) -> void:
	if _decided:
		return

	_decided = true
	_winner = winner
	_winner_name = why

	if authoritative and winner != 0:
		for id: StringName in players:
			if team_of(id) == winner:
				(players[id] as DrPlayer).points += config.winner_points

	DotLog.info(CHANNEL, "the round is decided", {"winner": winner, "why": why})


# --- The traps ---------------------------------------------------------------

## Each activator's hand on the buttons: a press is the use key going down near one.
##
## [b]An edge, made here from the held state[/b], as mg-wipeout made its grab: the key rides in
## every input packet, and a press sent as a reliable request would arrive a round trip after
## the key, which on a trap is a runner who was in it and now is not.
func _advance_buttons() -> void:
	for id: StringName in players:
		var player: DrPlayer = players[id]
		var pressed := player.wants_use and not bool(player.get_meta(&"use_held", false))
		player.set_meta(&"use_held", player.wants_use)

		if not pressed:
			continue

		if int(sides.get(id, 0)) != ACTIVATORS or not player.is_alive() or player.watching \
				or player.at_end:
			continue

		var index := stage.button_for(player.eye_position(), player.aim_direction(),
			config.button_reach, config.button_cone)

		if index < 0:
			continue

		var _fired := press(index, id)


## Fires trap [param index] for [param by], now, if it can be. What a button does, and what a
## suite and an admin do directly.
func press(index: int, by: StringName) -> bool:
	if stage == null or index < 0 or index >= stage.trap_count():
		return false

	if phase != Phase.RUN and phase != Phase.SHOWDOWN:
		button_refused.emit(by, "The traps are locked until the gate drops.")
		return false

	if not stage.trap_ready(index, _tick):
		button_refused.emit(by, "%s is spent." % stage.trap_name(index) if not stage.trap_running(index, _tick) \
			else "%s is still going." % stage.trap_name(index))
		return false

	stage.set_fired(index, _tick)
	pressed_by[index] = by
	trap_fired.emit(index, _tick, by)

	if progress != null and players.has(by):
		progress.on_pressed(by)

	DotLog.debug(CHANNEL, "a trap was pressed", {
		"trap": stage.trap_name(index), "by": String(by), "tick": _tick,
	})
	return true


## A press the server made, applied on a client: the trap and the tick it went on.
func apply_trap_fired(index: int, tick: int, by: StringName = &"") -> void:
	if stage == null:
		return

	stage.set_fired(index, tick)
	pressed_by[index] = by


## What the course did to everybody this tick: the traps, the pits, the drop and the finish.
##
## [b]A height comparison for the drop, not a trigger volume,[/b] as dot-timer and mg-wipeout
## both say: something falling fast crosses a thin trigger between two ticks without ever being
## inside it.
func _watch_course() -> void:
	if stage == null or stage.doc.is_empty() or phase == Phase.IDLE:
		return

	for id: StringName in players:
		var player: DrPlayer = players[id]

		# A death can decide the round, and dot-match can end it inside the call: nothing after
		# that is this round's.
		if phase == Phase.IDLE:
			return

		if not player.is_alive() or player.watching:
			continue

		var feet := player.controller.state.position

		if feet.y < stage.kill_height():
			_kill(player, _credited(id), DIED_FELL)
			continue

		if player.at_end:
			continue

		_note_reach(id, feet)

		var lethal := stage.lethal_at(feet, player.controller.state.is_crouched(), _tick)

		if lethal >= 0:
			_kill(player, lethal, DIED_TRAP)
			continue

		if lethal == DrCourse.KILLED_BY_COURSE:
			_kill(player, _credited(id), DIED_PIT)
			continue

		if int(sides.get(id, 0)) == RUNNERS and stage.in_finish(feet) \
				and (phase == Phase.RUN or phase == Phase.SHOWDOWN):
			_finish(player)


## Remembers the running trap somebody is in the reach of, for [constant CREDIT_SECONDS].
func _note_reach(id: StringName, feet: Vector3) -> void:
	for index in range(stage.trap_count()):
		if stage.trap_running(index, _tick) and stage.trap_zone(index).has_point(feet + Vector3(0.0, 0.5, 0.0)):
			_credit[id] = [index, _tick]
			return


## The trap a fall or a pit is credited to, or -1.
func _credited(id: StringName) -> int:
	var entry: Variant = _credit.get(id)

	if entry == null:
		return -1

	if _tick - int((entry as Array)[1]) > int(CREDIT_SECONDS * float(tick_rate)):
		return -1

	return int((entry as Array)[0])


## Kills [param player] for the course, credited to whoever pressed [param trap] (or nobody).
func _kill(player: DrPlayer, trap: int, why: StringName) -> void:
	if combat == null or player.health == null:
		return

	var by: StringName = pressed_by.get(trap, &"") if trap >= 0 else &""
	var attacker: DrPlayer = players.get(by)
	var damage := DotDamage.make(
		attacker.entity_id if attacker != null else 0, player.entity_id,
		player.health.max_health * 10.0, null
	)
	damage.point = player.controller.state.position
	damage.direction = Vector3.DOWN
	damage.tick = _tick
	damage.weapon_id = StringName("trap:%s" % str((stage.traps[trap]["spec"] as Dictionary)["id"])) \
		if trap >= 0 else why
	damage.context = {"why": why, "trap": trap}
	var _applied := combat.apply_damage(damage)


## A runner across the line: into the end arena, armed, and — if they are the first — the
## activators called down to meet them.
func _finish(player: DrPlayer) -> void:
	_finish_count += 1
	player.finished = true
	player.place = _finish_count
	player.finish_seconds = run_elapsed
	if authoritative and _finish_count == 1:
		player.points += config.first_across_points
	_send_to_end(player, true, _finish_count - 1)

	if progress != null:
		progress.on_finished(player.player_id, player.place, run_elapsed)

	player_finished.emit(player.player_id, player.place, run_elapsed)
	DotLog.debug(CHANNEL, "somebody finished", {
		"id": String(player.player_id), "place": player.place, "seconds": "%.2f" % run_elapsed,
	})

	if phase == Phase.RUN:
		_call_activators()


## The activators to the end, armed and a little tougher, because it is one against several.
##
## [b]All of them, and the buttons stop.[/b] The traps are the activators' and they are leaving
## them; a runner still on the course runs it with nobody pressing, which is the reward for
## the runner ahead getting there.
func _call_activators() -> void:
	_set_phase(Phase.SHOWDOWN)

	var seat := 0

	for player in players_on(ACTIVATORS):
		if not player.is_alive() or player.watching:
			continue

		_send_to_end(player, false, seat)
		seat += 1

		if player.health != null:
			player.health.max_health = config.player_health * config.activator_health_scale
			player.health.health = player.health.max_health

	DotLog.info(CHANNEL, "the activators were called to the end", {"activators": seat})


func _send_to_end(player: DrPlayer, runner: bool, seat: int) -> void:
	var spot := stage.end_spot(runner, seat)
	player.place_at(spot[0], spot[1])
	player.at_end = true
	_grace[player.player_id] = _tick + int(config.arrival_grace_seconds * float(tick_rate))

	if player.health != null:
		player.health.invulnerable = true

	var weapon: StringName

	if not runner and config.activator_weapon != "":
		weapon = StringName(config.activator_weapon)
	else:
		var pool := _weapon_pool()
		var draw := random.stream_for(&"end_weapon", round_number * 4096 + int(player.entity_id % 4096))
		weapon = pool[draw.next_range_i(0, pool.size() - 1)] if not pool.is_empty() else &""

	if weapon != &"":
		var _armed := arm(player, weapon)


## Ends the grace of everybody whose arrival was long enough ago.
func _advance_grace() -> void:
	for id: StringName in _grace.keys():
		if _tick < int(_grace[id]):
			continue

		_grace.erase(id)
		var player: DrPlayer = players.get(id)

		if player != null and player.health != null and not player.watching:
			player.health.invulnerable = false


## Which weapons a runner can be handed. Each one able to win a fight on its own, because the
## end is not a place to find a second.
func _weapon_pool() -> Array[StringName]:
	var out: Array[StringName] = []

	if not config.weapon_pool.is_empty():
		for id in config.weapon_pool:
			out.append(StringName(id))
		return out

	out.append_array([
		ZeeWeaponIds.REVOLVER, ZeeWeaponIds.SMG, ZeeWeaponIds.CARBINE, ZeeWeaponIds.RIFLE,
		ZeeWeaponIds.SHOTGUN, ZeeWeaponIds.MARKSMAN,
	])
	return out


static func _shuffle(items: Array, stream: DotRandomStream) -> void:
	for i in range(items.size() - 1, 0, -1):
		var j := stream.next_range_i(0, i)
		var held: Variant = items[i]
		items[i] = items[j]
		items[j] = held


# --- Weapons -----------------------------------------------------------------

## Hands [param player] a weapon, building their rig the first time.
func arm(player: DrPlayer, weapon_id: StringName) -> bool:
	if player.weapons == null:
		var rig := ZeeWeaponRig.new()
		rig.name = "Weapons"
		# SERVER on a server: the role only decides what is DRAWN, and a headless process has
		# no art to draw a view model from.
		rig.role = ZeeWeaponRig.Role.SERVER
		rig.authority = authoritative
		rig.tick_rate = tick_rate
		rig.player_ref = DotNodeRef.of_path(player.get_path())
		player.add_child(rig)

		var ready_now := rig.setup()

		if not ready_now.ok:
			DotLog.warn(CHANNEL, "a weapon rig would not set up", {
				"player": String(player.player_id), "why": ready_now.error.message,
			})
			player.remove_child(rig)
			rig.queue_free()
			return false

		player.weapons = rig

	if not player.weapons.give(weapon_id).ok:
		return false

	var def := player.weapons.arsenal.catalogue.get_def(weapon_id)

	if def != null:
		var _selected := player.weapons.arsenal.select(def.slot, _tick)
		player.wanted_slot = def.slot

	player_armed.emit(player.player_id, weapon_id)
	return true


func _disarm(player: DrPlayer) -> void:
	if player.weapons == null:
		return

	player.remove_child(player.weapons)
	player.weapons.queue_free()
	player.weapons = null


func _advance_weapons() -> void:
	if combat == null or (phase != Phase.RUN and phase != Phase.SHOWDOWN):
		return

	for id: StringName in players:
		var player: DrPlayer = players[id]

		if player.weapons == null or not player.is_alive() or player.watching or not player.at_end:
			continue

		var outcome := player.weapons.simulate_tick(weapon_command_for(player), _tick)

		for shot in outcome.shots:
			shot.attacker = player.entity_id
			shot.tick = _tick
			var _resolved := combat.resolve_shot(shot)


## A player's movement command as a weapon command: fire, alt-fire and reload are the
## movement command's three spare buttons; the slot is this game's own input message.
func weapon_command_for(player: DrPlayer) -> DotWeaponCommand:
	var command := DotWeaponCommand.new()
	var pending := player.controller.current_command

	if pending == null:
		return command

	command.set_button(DotWeaponCommand.BUTTON_ATTACK, pending.is_pressed(DotFpsCommand.BUTTON_USER_0))
	command.set_button(DotWeaponCommand.BUTTON_ALT, pending.is_pressed(DotFpsCommand.BUTTON_USER_1))
	command.set_button(DotWeaponCommand.BUTTON_RELOAD, pending.is_pressed(DotFpsCommand.BUTTON_USER_2))
	command.yaw = pending.yaw
	command.pitch = pending.pitch
	command.slot = player.wanted_slot
	return command


# --- The tick ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not authoritative or match_node == null or external_tick:
		return

	simulate(delta)


## One tick, counted by this world. What an offline client and the suite use.
func simulate(delta: float) -> void:
	_tick += 1
	_step(delta)


## One tick, numbered by the netcode. What the bridge uses. The step is still a fixed
## `1 / tick_rate`; a simulation stepped by a frame's delta runs differently on a bad second.
func tick_once(tick: int) -> void:
	if match_node == null:
		return

	_tick = tick
	_step(delta_for_tick())


func current_tick() -> int:
	return _tick


func _step(delta: float) -> void:
	_advance_phase(delta)

	if stage != null:
		stage.pose_at(_tick)

	_drive_bots()

	for id: StringName in players:
		var player: DrPlayer = players[id]

		# Nobody out is simulated: a body left to fall would fall for the rest of the round,
		# and one standing in a corridor would be a body the next runner collides with.
		if player.is_alive() and not player.watching:
			player.simulate(_tick, delta)

	_advance_buttons()
	_watch_course()
	_advance_grace()
	_advance_weapons()

	if combat != null:
		combat.tick(_tick, delta)

	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable() and phase == Phase.IDLE:
		return

	match_node.tick(_tick)


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


## Adopts a tick rate, on a client being told what the server runs at: this world, every
## player's controller and the stage, or the client walks at the wrong speed and is corrected
## for it on every snapshot.
func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	if stage != null:
		stage.tick_rate = rate

	for id: StringName in players:
		(players[id] as DrPlayer).tick_rate = rate

	if match_node != null and match_node.config != null:
		match_node.config.tick_rate = rate

	return true


# --- Bots -------------------------------------------------------------------

## What a stand-in does. A runner follows the document's route; an activator walks to the
## button of the trap the runners are about to reach and presses it when one is in it; either,
## at the end, fights.
func _drive_bots() -> void:
	for id: StringName in players:
		var player: DrPlayer = players[id]

		if not player.is_bot or not player.is_alive() or player.watching:
			continue

		var command := DotFpsCommand.new()
		command.yaw = player.controller.state.yaw
		command.pitch = player.controller.state.pitch

		if phase == Phase.IDLE or phase == Phase.COUNTDOWN:
			pass
		elif player.at_end:
			_bot_fight(player, command)
		elif int(sides.get(id, 0)) == ACTIVATORS:
			_bot_activate(player, command)
		else:
			_bot_run(player, command)

		player.controller.apply_command(command)


## A stand-in runner: along the route, and over every gap the route lands it across.
##
## [b]A `jump` point is where the jump LANDS, and the take-off is wherever the ground ends.[/b]
## A route that named take-off points as well needed one exactly at every edge, and the first
## version of this aimed the jump at the take-off point it was already standing on — which
## from a step past it is backwards; the bot jumped off the first block into the spikes
## behind it. So the bot runs at the landing and jumps when a ray finds no floor ahead,
## which is also what a person does.
func _bot_run(player: DrPlayer, command: DotFpsCommand) -> void:
	var route := stage.route()

	if route.is_empty():
		return

	var index := mini(int(_bot_route.get(player.player_id, 0)), route.size() - 1)
	var point: Dictionary = route[index]
	var at := player.controller.state.position
	var toward: Vector3 = (point["at"] as Vector3) - at
	toward.y = 0.0
	var grounded := player.controller.state.mode == DotFpsState.Mode.GROUND

	command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
	command.move = Vector2(0.0, 1.0)

	if bool(point["walk"]):
		command.set_button(DotFpsCommand.BUTTON_WALK, true)

	if bool(point["crouch"]):
		command.set_button(DotFpsCommand.BUTTON_CROUCH, true)

	# Just landed, and the next landing is somewhere else: stop first. A jump taken the tick
	# after a landing keeps the landing's momentum, which points the way the LAST jump went —
	# and the next floe is off to the side. Measured on Ice Works: a bot that never stopped
	# landed a metre and a half wide of the second floe, every time.
	#
	# And back to the middle of what it landed on before running at the next: stopped near the
	# far edge, there is no run-up, and the jump from a standstill fell short into the pool.
	if grounded and _bot_settle.has(player.player_id):
		var flat_speed := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()

		if flat_speed > 1.2:
			command.move = Vector2.ZERO
			return

		var middle: Vector3 = _bot_settle[player.player_id]
		var back := Vector3(middle.x - at.x, 0.0, middle.z - at.z)

		if back.length() > 0.35:
			command.yaw = rad_to_deg(atan2(-back.x, -back.z))
			command.set_button(DotFpsCommand.BUTTON_WALK, true)
			return

		_bot_settle.erase(player.player_id)

	if bool(point["jump"]):
		if not grounded:
			# In the air toward the landing: brake if the jump is going to carry past it.
			_bot_land_on(player, command, point["at"])
		elif toward.length() > float(point["reach"]) + 0.5:
			var heading := toward.normalized()
			var flat_speed := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
			# How fast a jump from here has to be going to come down on the landing: the
			# distance over a standing jump's time in the air.
			var airtime := 2.0 * sqrt(2.0 * config.jump_height / maxf(config.gravity, 0.1))
			var fast_enough := flat_speed * airtime >= toward.length() - 0.3

			# The edge: no floor a stride ahead, nor a little further (both, because a seam
			# between two floor pieces is a ray that finds nothing for one tick) — and going
			# fast enough to make it. Or no floor right in front, whatever the speed: from the
			# middle of a small block the stride ahead is already over the gap, and the first
			# version took off from there at walking pace and fell short.
			var at_edge := not _floor_at(at + heading * 0.35)
			var gap_ahead := not _floor_at(at + heading * 0.7) and not _floor_at(at + heading * 1.4)

			if at_edge or (gap_ahead and fast_enough):
				# A fumble is a jump not taken, decided once per bot, waypoint and round, so it
				# is reproducible and a different bot fumbles a different jump.
				var draw := random.stream_for(&"bot_fumble",
					round_number * 65536 + int(player.entity_id % 256) * 256 + index)

				if draw.next_range_f(0.0, 100.0) >= config.bot_fumble_chance:
					command.set_button(DotFpsCommand.BUTTON_JUMP, true)

	_bot_unstick(player, command)

	if toward.length() > float(point["reach"]):
		return

	# A landing is not reached until the bot is on its feet on it.
	if bool(point["jump"]) and not grounded:
		return

	if bool(point["jump"]) and index + 1 < route.size() and bool((route[index + 1] as Dictionary)["jump"]):
		_bot_settle[player.player_id] = point["at"]

	_bot_route[player.player_id] = index + 1


## Whether there is something to stand on under [param point], within a metre and a half down.
## A ray through the world layer, so a trapdoor that has opened is not a floor.
func _floor_at(point: Vector3) -> bool:
	var world := get_world_3d()

	if world == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(point + Vector3(0.0, 0.5, 0.0), point + Vector3(0.0, -1.5, 0.0))
	query.collision_mask = physics.layer_mask(&"world") if physics != null else 1
	return not world.direct_space_state.intersect_ray(query).is_empty()


## Steers a bot in the air so it comes down on [param target] rather than past it.
##
## [b]Measured along the way it is going, not along the line to the target.[/b] mg-wipeout's
## version projected the overshoot onto the direction of the target, which is right while the
## target is ahead and wrong once it is nearly underneath: a block half a metre to the side
## projects a two-metre overshoot onto almost nothing, and the bot stopped braking over the
## block it then sailed past. Here the landing is predicted, the overshoot is how far past
## the target it is along the velocity, and the brake is the constant deceleration that takes
## exactly that much off in the time left — `2·over / t²`, spread over the ticks.
func _bot_land_on(player: DrPlayer, command: DotFpsCommand, target: Vector3) -> void:
	var state := player.controller.state
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)

	if flat.length() < 0.3 or Vector2(target.x - state.position.x, target.z - state.position.z).length() > 7.0:
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


## Jumps when the bot has been running for a second and got nowhere.
func _bot_unstick(player: DrPlayer, command: DotFpsCommand) -> void:
	var at := player.controller.state.position
	var mark: Array = _bot_stuck.get(player.player_id, [])

	if mark.is_empty() or _tick - int(mark[1]) >= tick_rate:
		var stuck := not mark.is_empty() and command.move != Vector2.ZERO \
			and Vector2(at.x - (mark[0] as Vector3).x, at.z - (mark[0] as Vector3).z).length() < 0.4

		if stuck and player.controller.state.mode == DotFpsState.Mode.GROUND:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)

		_bot_stuck[player.player_id] = [at, _tick]


## A stand-in at the buttons: to the button of the trap a runner will reach first, and a press
## once somebody has been in it for [member DrConfig.bot_trap_delay].
##
## [b]It walks to buttons in a straight line[/b], so a course's activator corridor has to be
## one a person can walk straight along; every course in this repository's is, and the suite
## runs every one with a stand-in at the buttons.
func _bot_activate(player: DrPlayer, command: DotFpsCommand) -> void:
	var target := _bot_target_trap()

	if target < 0:
		return

	var eyes := player.eye_position()
	var button := stage.button_point(target)
	var flat := Vector3(button.x - eyes.x, 0.0, button.z - eyes.z)

	if flat.length() > config.button_reach * 0.6:
		command.yaw = rad_to_deg(atan2(-flat.x, -flat.z))
		command.move = Vector2(0.0, 1.0)
		player.wants_use = false
		_bot_unstick(player, command)
		return

	var look := button - eyes
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)

	var zone := stage.trap_zone(target)
	var someone_in := false

	for runner in players_on(RUNNERS):
		if runner.is_alive() and not runner.watching and not runner.at_end \
				and zone.has_point(runner.controller.state.position + Vector3(0.0, 0.5, 0.0)):
			someone_in = true
			break

	if not someone_in:
		_bot_watch.erase(player.player_id)
		player.wants_use = false
		return

	var since: int = _bot_watch.get(player.player_id, _tick)
	_bot_watch[player.player_id] = since

	# Released and pressed again, so the server sees an edge every other tick it is wanted.
	player.wants_use = _tick - since >= int(config.bot_trap_delay * float(tick_rate)) \
		and not player.wants_use


## The ready trap the nearest live runner is closest to reaching.
func _bot_target_trap() -> int:
	var best := -1
	var best_distance := INF

	for index in range(stage.trap_count()):
		if not stage.trap_ready(index, _tick):
			continue

		var zone := stage.trap_zone(index)

		for runner in players_on(RUNNERS):
			if not runner.is_alive() or runner.watching or runner.at_end:
				continue

			var at := runner.controller.state.position
			# Ahead of a runner or around them, never wholly behind: a trap the runners have
			# passed is not one to walk back to. Every course runs along -Z.
			if zone.position.z > at.z + 0.5:
				continue

			var distance := at.distance_to(zone.get_center())

			if distance < best_distance:
				best_distance = distance
				best = index

	return best


func _bot_fight(player: DrPlayer, command: DotFpsCommand) -> void:
	var enemy := _nearest_enemy(player)

	if enemy == null:
		return

	_aim_bot(player, command, enemy)
	var distance := enemy.controller.state.position.distance_to(player.controller.state.position)

	if distance > 7.0:
		command.move = Vector2(0.0, 1.0)
	elif distance < 3.0:
		command.move = Vector2(0.0, -1.0)
	else:
		# Sideways, a step each second the other way: a bot that stands still to shoot is a
		# bot that is shot.
		command.move = Vector2(1.0 if (_tick / tick_rate) % 2 == 0 else -1.0, 0.0)


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


func _aim_bot(player: DrPlayer, command: DotFpsCommand, target: DrPlayer) -> void:
	var toward := target.eye_position() - player.eye_position()

	if toward.length() < 0.01:
		return

	# A hand of its own per bot per round, with the round mixed into the subject: without it
	# mg-smash-copter's empty server played the same fight twelve times out of twelve.
	var hand: Variant = _bot_hands.get(player.player_id)

	if hand == null:
		var draw := random.stream_for(&"bot_aim", round_number * 8192 + int(player.entity_id % 8192))
		var spread := config.bot_aim_spread_degrees
		hand = Vector2(draw.next_range_f(-spread, spread), draw.next_range_f(-spread * 0.4, spread * 0.4))
		_bot_hands[player.player_id] = hand

	command.yaw = rad_to_deg(atan2(-toward.x, -toward.z)) + (hand as Vector2).x
	command.pitch = clampf(
		rad_to_deg(asin(clampf(toward.normalized().y, -1.0, 1.0))) + (hand as Vector2).y, -89.0, 89.0
	)
	command.set_button(DotFpsCommand.BUTTON_USER_0, true)


# --- Reacting ---------------------------------------------------------------

func _on_player_died(player: DrPlayer, damage: DotDamage) -> void:
	var by := entities.key_for_id(damage.attacker)
	var why: StringName = damage.context.get("why", DIED_SHOT)

	# Spectating and progress BEFORE dot-match: `report_kill` can end the round inside the
	# call, and a kill counted after that is counted in no round. mg-smash-copter's finding.
	if spectate != null and authoritative:
		spectate.on_died(
			player.player_id, by, why == DIED_FELL,
			damage.point if damage.point != Vector3.ZERO else player.global_position,
			stage.kill_height() + 8.0, _tick
		)

	if progress != null:
		progress.on_died(player.player_id, by, why)

	if match_node != null and DotEntity.is_kind(player.entity_id, DotEntity.KIND_PLAYER):
		match_node.report_kill(String(by), String(player.player_id), why, _tick)

	player_died.emit(player.player_id, by, why)
	DotLog.debug(CHANNEL, "player died", {
		"id": String(player.player_id), "by": String(by), "why": String(why),
	})


# --- Reporting --------------------------------------------------------------

func seconds_left() -> float:
	match phase:
		Phase.COUNTDOWN:
			return maxf(config.countdown_seconds - phase_elapsed, 0.0)
		Phase.RUN, Phase.SHOWDOWN:
			return maxf(round_limit() - run_elapsed, 0.0)
		_:
			return 0.0


func describe() -> Dictionary:
	var used := 0

	if stage != null:
		for index in range(stage.trap_count()):
			if not stage.trap_ready(index, _tick):
				used += 1

	return {
		"round": round_number,
		"phase": Phase.keys()[phase],
		"left": "%.0f s" % seconds_left(),
		"course": str(course_doc.get("id", "-")),
		"players": players.size(),
		"runners": alive_on(RUNNERS),
		"activators": alive_on(ACTIVATORS),
		"finished": _finish_count,
		"traps": "%d of %d spent" % [used, stage.trap_count() if stage != null else 0],
		"decided": _winner_name if _decided else "-",
		"courses": catalogue.courses.size() if catalogue != null else 0,
		"phase_id": phase,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["deathrun, round %d" % round_number])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])

	for player in players_on(ACTIVATORS):
		lines.append("  activator  %s%s" % [player.display_name, "" if player.is_alive() else " (out)"])

	if stage != null:
		lines.append_array(stage.describe_lines())

	return lines
