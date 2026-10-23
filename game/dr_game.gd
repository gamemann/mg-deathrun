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

## Where a host that runs this game with no server (the client shell's Solo play) publishes
## the map packs it mounted for it. See [method solo_map_dirs].
const SOLO_SERVICE := &"dot_solo"

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

## What the stand-ins are called, solo and on a server, through dot-bot's [DotBotNames]
## (never doubled up, and numbered only past the end of the list). Not "Stand-in 2": a board of
## numbered stand-ins tells a player they are alone.
const BOT_NAMES := ["Lever", "Pressure Plate", "Tripwire", "Pitfall", "Hinge", "Ratchet", "Sprocket", "Fuse"]

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

## A weapon's shot took health off somebody: to [param player_id], the shooter, for the hit
## marker and the hit drawn on the body. The server's word, never a client's prediction.
signal hit_landed(player_id: StringName, point: Vector3, killed: bool, headshot: bool)

@export var config: DrConfig = null

## Whether this instance decides anything. A client sets this false.
@export var authoritative: bool = true

@export_range(1, 240, 1) var tick_rate: int = 64

## Whether something else drives the tick: the bridge, on both ends.
@export var external_tick: bool = false

## Asked every tick of a world that ticks itself: true while a cover is up (the client's load
## gate). Only the bodies are stepped then, so they settle onto the floor, and the phase, the
## buttons, the course's deaths, the bots and the round clock wait. Unset, never held.
var hold_clock: Callable = Callable()

## Whether this world publishes itself under [constant SERVICE].
@export var register_service: bool = true

## Whether the stage draws its sky and its void. A client sets it.
@export var draw_world: bool = false

var stage: DrCourse = null
var catalogue: DrCatalogue = null
var combat: DotCombatManager = null

## `func(player_id: StringName) -> bool`: whether a player may be hurt now, assigned by the
## module from dot-game's `can_peer_be_harmed`. Unset offline, and a bot is never loading.
var harm_gate: Callable = Callable()
var match_node: DotMatch = null
var random: DotRandomManager = null
var physics: DotPhysicsLayout = null

## What a dead body does, and which death reactions the server allows: dot-player-char's
## `sv_ragdoll*` cvars, bound by the module (REPLICATED) and followed by a client through its
## link, because the client draws the bodies. The game's, not the course's.
var ragdoll_rules: DotPlayerRagdollRules = DotPlayerRagdollRules.new()

## dot-props' `sv_toys*` (whether a course's toys are there, how many simulate at once, how hard a
## walk pushes one). Bound by the module (REPLICATED) and followed by a client, which draws them.
var toy_rules: DotPropToyRules = DotPropToyRules.new()

## dot-player-controller's `mp_forceview` (may a player switch to third person) and
## `mp_solidplayers` (do players and stand-ins block each other). Bound by the module
## (REPLICATED) and followed by a client through its link: the client places its camera
## under the first and predicts its own player under the second.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()


func _init() -> void:
	# This game's pick: runners pass through each other (see `_build_physics`). An owner who
	# wants bodies sets `mp_solidplayers 1`.
	body_rules.solid = false

## The weapon definitions by id, for the death reaction a weapon asks for. Built on first use.
var _weapon_defs: Dictionary = {}
var effects: DotFxManager = null
var spectate: DrSpectate = null
## Who a spectator may watch and whether they may fly a free camera: dot-spectate's
## `mp_forcecamera`, `mp_freeroam` and `mp_freeroam_speed`. One object for the life of the
## game, shared with [DrSpectate]'s manager, so a cvar change reaches the rules in use. Bound
## by the module (REPLICATED) and followed by a client, which is the end that flies the camera.
var spectate_rules: DotSpectatorRules = DotSpectatorRules.new()
var progress: DrProgress = null

## player id -> DrPlayer.
var players: Dictionary = {}

## The course the next round plays, set by the players' vote ([code]game/dr_vote.gd[/code]) or
## an operator, and used once. Empty lets the rotation choose.
var next_course_id: StringName = &""

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
## Stand-in activators: player id -> the walkway point they last reached (-1: still at the spawn).
var _bot_walk: Dictionary = {}
## Stand-in activators: player id -> [the trap they head for, the tick it was chosen].
var _bot_goal: Dictionary = {}
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
	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)
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
		# Solo in the client shell: the map packs it mounted for this game, which a server
		# would have named. See [method solo_map_dirs].
		for root in solo_map_dirs("courses"):
			var _added := catalogue.add_directory(root)
		# The Workshop's courses, solo only by the index's own session (an online session lists none).
		catalogue.follow_content(DotContentIndex.shared(), DrCatalogue.accepted_map_kinds())
		var _rotation := load_rotation()
		# Laid out now, not on the first round: dot-match runs a warmup first, and an empty
		# world through the warmup is indistinguishable from a map that failed to load.
		_lay_out_course()

	if register_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(CHANNEL, "world ready", config.describe())


## The `<pack>/<subdir>` directories of the map packs a host running this game with no server
## has mounted for it: the client shell's Solo play, which fetches the packs a server owner
## would name (dot-server-deploy's `client/solo.json`) because a tab has no server to name
## them. Read the way the module reads its server's ([DotGameContent]). Empty everywhere else:
## a server, a suite, a run from the repository. Looked up by name and duck-typed, because a
## delivered game may not name a host's class.
static func solo_map_dirs(subdir: String) -> PackedStringArray:
	var host: Object = DotRegistry.get_service(SOLO_SERVICE)
	if host == null or not host.has_method(&"map_dirs"):
		return PackedStringArray()
	return host.call(&"map_dirs", subdir)


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

## The player's motor mask under `mp_solidplayers`, and the standing hull the others stop at
## (a player's body has no shape of its own). Through `apply_to`: `set_collision_mask`, which
## a style does not undo, and the players' layer as one a player may walk out of. With the rule
## on, a stand-in stops at your shoulder instead of walking through your face (the first
## play test).
func _apply_body_mask(player: DrPlayer) -> void:
	if physics == null or player == null or player.controller == null:
		return
	body_rules.apply_to(player.controller, physics.collision_mask(&"player"), physics.layer_mask(&"player"))
	var tunables := player.controller.tunables
	body_rules.apply_hull(player, tunables.stand_height, tunables.radius)


## `mp_solidplayers` changed: every player's mask and hull now.
func _on_body_rules_changed() -> void:
	for id in players:
		_apply_body_mask(players[id] as DrPlayer)


## The named collision layers: the world and the players.
func _build_physics() -> void:
	physics = DotPhysicsLayout.custom(&"deathrun", [&"world", &"player", &"toy", &"footprint"])

	for layer in physics.layers:
		match layer.id:
			&"player":
				# Not other players. Two runners shoving on a ledge is a race decided by who
				# walked into whom, drawn in the past on every client — and on a course where a
				# shove is a death, it would be the deadliest thing on it. So `mp_solidplayers`
				# is 0 by default here (see `body_rules`); the camera fade keeps a runner who
				# walks through you out of the lens.
				layer.collides_with = [&"world"]
			# A course's loose toy (dot-props'): the course, its traps and the other toys,
			# never a runner, who walks through it and pushes it (`_advance_toys`).
			&"toy":
				layer.collides_with = [&"world", &"toy"]
			# A toy's footprint, for a walkable mesh's bake only: nothing collides with it.
			&"footprint":
				layer.collides_with = []
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
	stage.authoritative = authoritative
	stage.toy_rules = toy_rules
	stage.gravity = config.gravity
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

	# dot-game's "still loading": the one place every hurt passes (a trap's kill, the floor, a
	# weapon), so a covered seat is neither hurt nor eliminated, and a round counts the living
	# from health. An admin's slay or slap is the operator's word and passes.
	combat.resolver.adjust = func(damage: DotDamage) -> void:
		if damage.context.get("admin", false):
			return

		if not can_be_harmed(entities.key_for_id(damage.victim)):
			damage.refuse("still loading")

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


## The intermission is the pause plus the killcam the clients play inside it, so the server never waits on one.
func apply_intermission(rules: DotMatchRules = null) -> void:
	var target: DotMatchRules = rules if rules != null else (match_node.rules if match_node != null else null)
	if target == null:
		return
	var pause := config.intermission_seconds
	target.intermission_sec = pause + (config.killcam_seconds if pause > 0.0 else 0.0)


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
	apply_intermission(rules)
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

	# The config's number is only the starting point: from here `mp_forcecamera` is the rule.
	spectate_rules.force_camera = clampi(config.spectate_camera, 0, 2)
	var ready_now := spectate.setup(authoritative, tick_rate, spectate_rules)

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
		_apply_body_mask(player)

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

	for table in [_bot_route, _bot_walk, _bot_goal, _bot_hands, _bot_watch, _bot_stuck, _bot_settle, _credit, _grace]:
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


## Whether [param player_id] may be damaged or eliminated now: false while their client is behind
## its loading cover. True for anybody the gate does not know (bots, offline).
func can_be_harmed(player_id: StringName) -> bool:
	return not harm_gate.is_valid() or bool(harm_gate.call(player_id))


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
		# And the toys home, which a warmup kicked about.
		if stage.toys != null:
			stage.toys.reset()
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
	var ids: Array[StringName] = []
	for id: StringName in players.keys():
		ids.append(id)
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	# The players' own choices: a volunteer is drawn first, anybody who asked to run only if
	# the round would otherwise be short of an activator, because there must always be one.
	var wishes := {}
	if config.allow_side_choice:
		for id in ids:
			match (players[id] as DrPlayer).side_wish:
				ACTIVATORS:
					wishes[id] = 1
				RUNNERS:
					wishes[id] = -1

	# A seat still behind its loading cover is the last choice for an activator: its buttons
	# would sit unpressed (and its traps unaimed) while it cannot see. Treated as asking to
	# run, so it is drawn only when the round would otherwise have no activator.
	for id in ids:
		if not can_be_harmed(id):
			wishes[id] = -1

	# dot-team's draw, which was extracted from this one. rest_first keeps this game's rule:
	# last round's activators sit out even if they volunteered, and come back only when there
	# are not enough fresh names (unless the server lets them repeat).
	var history := {}
	DotTeamRotation.note(history, ids, _last_activators, 0)
	var result := DotTeamRotation.pick(
		ids, config.activators_for(ids.size()), DotTeamRotation.Mode.RANDOM, history,
		random.stream(&"activators").next(), wishes, config.activator_may_repeat, true
	)
	var drawn: Array[StringName] = []
	drawn.assign(result["picked"])

	_last_activators = drawn

	for id in ids:
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

	var doc: Dictionary = {}

	# What the players voted for, once, if it is still a course this server plays (a
	# dr_reload between the vote and the round can take it away). The rotation otherwise.
	if next_course_id != &"" and catalogue.playable_courses(config.course_ids).has(next_course_id):
		doc = catalogue.courses[next_course_id]

	next_course_id = &""

	if doc.is_empty():
		doc = catalogue.next_course(
			config.course_ids, config.shuffle_courses, random.stream(&"course"),
			StringName(str(course_doc.get("id", "")))
		)

	catalogue.note_played(StringName(str(doc.get("id", ""))))
	build_stage(with_tell(doc, config.trap_tell_seconds))
	_place_everybody()
	_course_unplayed = true


## Reads maps.yml (the `--config` directory first) and applies it. Called at boot and by
## `sv_map_rotation_file`. A file that is present and unreadable is an ERROR and changes nothing:
## rotating every course is a better failure than rotating none.
func load_rotation() -> DotResult:
	if catalogue == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no catalogue to rotate.")

	var stem := config.map_rotation_file
	var dir := DotMapRotationFile.config_dir_arg()
	DotAddonConfig.game = "mg-deathrun"
	var found := DotMapRotationFile.find(stem, dir)

	if found == "" and stem != "" and (dir != "" or stem != DrConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every course rotates", {
			"file": stem, "config_dir": dir,
		})

	var paths := PackedStringArray()

	if found != "":
		# The layers that apply (an operator file replaces the shipped one unless it says merge: true); a named file or the legacy file stands alone.
		var layers := DotMapRotationFile.find_layers(dir, "mg-deathrun")
		paths = layers if layers.has(found) else PackedStringArray([found])

	var read := DotMapRotationFile.load_files(paths, "mg-deathrun")

	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every course rotates", {
			"why": read.error.message,
		})
		catalogue.rotation_file = null
		catalogue.apply_rotation(config.course_ids)
		return read

	catalogue.rotation_file = read.value
	catalogue.apply_rotation(config.course_ids)

	if catalogue.has_rotation_file():
		DotLog.info(CHANNEL, "the map rotation file", {
			"paths": ", ".join(catalogue.rotation_file.sources),
			"active": catalogue.rotation_file.active_name(),
		})

	return read


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func rotation_commands() -> Dictionary:
	if catalogue == null or catalogue.rotation_file == null:
		return {}

	return catalogue.rotation_file.commands()


## Every name a role of this game's own answers to (the first is the one help shows), from
## maps.yml's `commands:` block; the role's own name with no file.
func command_names(role: String) -> PackedStringArray:
	var names: Dictionary = rotation_commands().get("names", {})

	if not names.has(role):
		return PackedStringArray([role])

	return DotCommandNames.all_of("", names, {}, role)


## Every course this server plays, as the map menu (M) lists them: `{id, name, detail,
## current}`, the blurb under the name (a course's `theme` is its colours, not a word). Solo the
## client's list, online the server's (the module hands it to dot-vote's map menu).
func course_rows() -> Array:
	var out: Array = []
	if catalogue == null:
		return out
	var now := StringName(str(course_doc.get("id", "")))
	for id in catalogue.playable_courses(config.course_ids):
		var doc: Dictionary = catalogue.courses.get(id, {})
		var rotates := catalogue.in_rotation(id)
		var row := {"id": String(id),
			"name": catalogue.label_of(id) + ("" if rotates else " (not in rotation)"),
			"in_rotation": rotates, "current": id == now,
			"detail": str(doc.get("blurb", ""))}
		if doc.has("thumbnail"):
			row["thumbnail"] = str(doc["thumbnail"])
		out.append(row)
	return out


## The map menu's change: [param id] now, not after this round. The next course is set and a
## fresh round begins on it (dot-match's `begin_round_now`: the round called off has no
## winner and no activator's score); with no match running it is simply built. Authority only.
func change_course_now(id: StringName) -> DotResult:
	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "Only the server changes the course.")
	if catalogue == null or not catalogue.playable_courses(config.course_ids).has(id):
		return DotResult.fail(DotError.CODE_INVALID, "There is no course called '%s' here." % id)
	next_course_id = id
	# The warmup's course is not the one to keep: the next round is the chosen one.
	_course_unplayed = false
	if match_node == null or not match_node.begin_round_now(_tick):
		_lay_out_course()
	DotLog.info(CHANNEL, "course changed from the map menu", {"course": String(id)})
	return DotResult.success(id)


## [param doc] with [param tell] seconds added to every trap's delay: the tell, written into the
## document itself so the course a client is sent and the course the server runs move every
## trap at the same tick. A copy: the catalogue's documents stay as their files say.
static func with_tell(doc: Dictionary, tell: float) -> Dictionary:
	if tell <= 0.0:
		return doc

	var out: Dictionary = doc.duplicate(true)

	for trap: Dictionary in out.get("traps", []):
		var timing: Dictionary = trap.get("timing", {})
		timing["delay"] = float(timing.get("delay", 0.0)) + tell
		timing["tell"] = tell

	return out


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
		_bot_walk[player.player_id] = -1

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

		# A teleport already moved them, inside their own tick (DrPlayer._after_tick: the same on
		# a predicting client); what is left for the server is a stand-in, which carries on from
		# the route point nearest where it landed.
		if player.teleported:
			player.teleported = false
			var as_runner := int(sides.get(id, 0)) == RUNNERS

			if player.is_bot and as_runner:
				_bot_route[player.player_id] = _route_after(feet, int(_bot_route.get(player.player_id, 0)))
			elif player.is_bot:
				_bot_walk[player.player_id] = _walk_after(feet, int(_bot_walk.get(player.player_id, -1)))

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


## The route point a stand-in sent to [param landed] carries on to: the nearest one at or after
## [param from_index], so it never turns back for a point it has already passed.
func _route_after(landed: Vector3, from_index: int) -> int:
	var route := stage.route()
	var best := from_index
	var best_distance := INF

	for i in range(from_index, route.size()):
		var distance := ((route[i] as Dictionary)["at"] as Vector3).distance_to(landed)

		if distance < best_distance:
			best_distance = distance
			best = i

	return best


## The walkway point a stand-in activator sent to [param landed] carries on from: the nearest one
## at or after [param from_index], as it has already walked everything before.
func _walk_after(landed: Vector3, from_index: int) -> int:
	var points := stage.walkway()
	var best := from_index
	var best_distance := INF

	for i in range(maxi(from_index, 0), points.size()):
		var distance := ((points[i] as Dictionary)["at"] as Vector3).distance_to(landed)

		if distance < best_distance:
			best_distance = distance
			best = i

	return best


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
			_shoot_toys(shot)
			var resolved := combat.resolve_shot(shot)
			_note_hits(player, resolved)


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

	if hold_clock.is_valid() and hold_clock.call():
		_step_bodies_only(delta)
		return

	_step(delta)


## A tick under a cover: the bodies move, nothing else happens. A body that is not alive or is
## watching is left alone, as in [method _step].
func _step_bodies_only(delta: float) -> void:
	for id: StringName in players:
		var body: DrPlayer = players[id]

		if body.is_alive() and not body.watching:
			body.simulate(_tick, delta)


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

	if authoritative:
		_advance_toys(delta)

	if combat != null:
		combat.tick(_tick, delta)

	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable() and phase == Phase.IDLE:
		return

	match_node.tick(_tick)


# --- Toys ----------------------------------------------------------------------

## Everybody against the course's toys, after they moved: a walk into a ball sends it on; then
## the box's own tick (the awake cap, the lost sent home). Server side.
func _advance_toys(delta: float) -> void:
	if stage == null or stage.toys == null or stage.toys.count() == 0:
		return
	for id: StringName in players:
		var player: DrPlayer = players[id]
		if not player.is_alive() or player.watching:
			continue
		var state := player.controller.state
		var tunables := player.controller.tunables
		var radius := tunables.radius if tunables != null else 0.35
		var height := lerpf(tunables.stand_height, tunables.crouch_height, state.crouch_fraction) if tunables != null else 1.8
		var _pushed := stage.toys.push_from(state.position, state.velocity, radius, height)
	stage.toys.advance(delta)


## An armed runner's shot against the toys: the first one on its ray, nearer than a wall, is
## pushed (dot-props' `shot_along`). The shot goes on to the combat, whose trace never sees a
## toy, so a ball is never cover in the arena. Server side.
func _shoot_toys(shot: DotShot) -> void:
	if not authoritative or stage == null or stage.toys == null or stage.toys.count() == 0:
		return
	var directions: Array = shot.pellets if not shot.pellets.is_empty() else [shot.direction]
	for raw: Variant in directions:
		var _pushed := stage.toys.shot_along(shot.origin, raw as Vector3, maxf(shot.max_range, 1.0), shot.damage, physics.layer_mask(&"world"))


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
			# Brake against the motion rather than coast: letting go leaves friction alone to
			# take a landing's 5 m/s down to a stand, which was most of a second per jump.
			var v := player.controller.state.velocity
			command.yaw = rad_to_deg(atan2(-v.x, -v.z))
			command.move = Vector2(0.0, -1.0)
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
		elif toward.length() > float(point["reach"]) + 0.5 or at.y < (point["at"] as Vector3).y - 0.5:
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

	# Nor from the foot of the step it is on: reach is flat, and a landing 1.2 m back on top of
	# a 0.94 m riser was ticked off by a bot standing against the riser, which then walked into
	# the face toward the next point and waited a second for the unstick jump, on every step.
	# (The take-off above is allowed that close for the same reason: still below the landing.)
	if bool(point["jump"]) and at.y < (point["at"] as Vector3).y - 0.5:
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
	var target := _bot_target_trap(player)

	if target < 0:
		return

	var eyes := player.eye_position()
	var button := stage.button_point(target)

	if not bot_walk_toward(player, target, command):
		player.wants_use = false
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
	# The operator's delay, scaled by how quickly this preset reacts (`bot_reaction` against
	# medium's): medium presses exactly when it always did, easy later, nightmare sooner.
	var reacts := DotBotSettings.of(self).profile.reaction / _MEDIUM_BOT.reaction
	player.wants_use = _tick - since >= int(config.bot_trap_delay * reacts * float(tick_rate)) \
		and not player.wants_use


## The preset the bots' numbers are taken relative to, so medium plays as before presets.
## Fewest walkway points a round's first step may skip, counting from the spawn (point -1).
const WALKWAY_SKIP_MIN := 8

static var _MEDIUM_BOT: DotBotProfile = DotBotProfile.new()


## Walks a stand-in activator one step toward trap [param index]'s button and says whether it
## is there (close enough to press). A course with a `walkway` names the points to walk through
## (forward or back, to the point that trap's button is pressed from); without one, or for a
## button the walkway does not name, it is straight at the button.
func bot_walk_toward(player: DrPlayer, index: int, command: DotFpsCommand) -> bool:
	var eyes := player.eye_position()
	var button := stage.button_point(index)
	var goal := button
	var points := stage.walkway()
	var stop := stage.walkway_stop(index) if not points.is_empty() else -1

	if stop >= 0:
		var here: int = int(_bot_walk.get(player.player_id, -1))

		if here != stop:
			if here < 0:
				here = _walkway_shortcut(player, points, here, stop)
				_bot_walk[player.player_id] = here
			var next := here + (1 if here < stop else -1)
			var point: Dictionary = points[next]
			goal = point["at"]
			var gap := Vector2(goal.x - player.controller.state.position.x, goal.z - player.controller.state.position.z).length()

			if gap <= float(point["reach"]):
				_bot_walk[player.player_id] = next

	var flat := Vector3(goal.x - eyes.x, 0.0, goal.z - eyes.z)

	if goal != button or flat.length() > config.button_reach * 0.6:
		command.yaw = rad_to_deg(atan2(-flat.x, -flat.z))
		command.move = Vector2(0.0, 1.0)
		_bot_unstick(player, command)
		return false

	return true


## The walkway point to count as already reached at the start of a round: the one nearest
## [param stop] (by position in the list) that is close and in the open.
## A tour that runs the whole course in one order revisits its own corridors, so without this
## an activator spawned beside the stretch it needs walked the tour from the start and
## arrived after every runner had passed.
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


## The ready trap this activator can reach in time and a runner is closest to: the buttons it
## would arrive at before the runner has passed (walking its walkway at run speed), else the one
## it is likeliest to catch. Chosen by distance alone, an activator spawned far from the first
## trap walked toward a button it could never reach while every runner went by. Re-chosen
## twice a second, so it does not turn round on every step.
func _bot_target_trap(player: DrPlayer = null) -> int:
	if player != null:
		var held: Array = _bot_goal.get(player.player_id, [])

		if not held.is_empty() and _tick - int(held[1]) < tick_rate / 2 and stage.trap_ready(int(held[0]), _tick):
			return int(held[0])

	var best := -1
	var best_score := INF

	for index in range(stage.trap_count()):
		if not stage.trap_ready(index, _tick):
			continue

		var zone := stage.trap_zone(index)
		var arrive := _bot_walk_distance(player, index) / maxf(config.run_speed, 0.1) if player != null else 0.0

		for runner in players_on(RUNNERS):
			if not runner.is_alive() or runner.watching or runner.at_end:
				continue

			var at := runner.controller.state.position
			# Ahead of a runner or around them, never wholly behind: a trap the runners have
			# passed is not one to walk back to. A course with a route is measured along it (it
			# may bend); one without runs along -Z.
			var ahead := stage.route_progress(zone.get_center())

			if ahead >= 0:
				if ahead < stage.route_progress(at):
					continue
			elif zone.position.z > at.z + 0.5:
				continue

			var distance := at.distance_to(zone.get_center())
			# Seconds late, with a second's grace for the zone's width; ties go to the nearer zone.
			var late := maxf(arrive - distance / maxf(config.run_speed, 0.1) - 1.0, 0.0)
			var score := late * 100.0 + distance * 0.001

			if score < best_score:
				best_score = score
				best = index

	if player != null:
		_bot_goal[player.player_id] = [best, _tick]

	return best


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


## Aims a stand-in at [param target] the way a person does and says whether it fires this
## tick: dot-bot's [DotBotAim] on this game's `bot_difficulty`, so the view turns at
## `bot_turn_rate`, the first shots miss by `bot_aim_error` and settle, and the trigger waits
## `bot_reaction` after first sight. It used to snap onto the target on the first tick and hold
## the trigger, off by one random `dr_bot_spread` per round.
##
## [b]Seeded per bot and per round[/b], so an empty server does not play the same fight every
## round (mg-smash-copter's finding).
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

	# How the body falls, picked once, here, and carried on DEATH to every client.
	if authoritative:
		player.death = decide_death(player, damage)

	player_died.emit(player.player_id, by, why)
	DotLog.debug(CHANNEL, "player died", {
		"id": String(player.player_id), "by": String(by), "why": String(why),
	})


## The fall a death gets: dot-player-char's reaction rule over the server's weights, seeded from
## the player and the tick, with the killing weapon's def (zee's sniper and launcher always throw
## the body). A trap kills "downward", which pushes nothing; the body just drops.
func decide_death(player: DrPlayer, damage: DotDamage) -> DotPlayerDeath:
	if _weapon_defs.is_empty():
		_weapon_defs = ZeeWeaponPack.table()
	var direction := damage.direction
	var attacker: DrPlayer = players.get(entities.key_for_id(damage.attacker)) if damage.attacker != 0 else null
	if direction.length_squared() < 0.0001 and attacker != null and attacker != player:
		direction = player.controller.state.position - attacker.controller.state.position
	return DotPlayerDeath.decide(
		ragdoll_rules.reactions(), damage.is_headshot(), damage.amount, direction,
		DotPlayerDeath.seed_of(player.entity_id, _tick), _weapon_defs.get(damage.weapon_id)
	)


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


## Every damage a weapon's shot did to somebody else, as [signal hit_landed] for the shooter.
## Only what took health and only on the authority: a refused hit, a dead body or the
## shooter's own splash is no confirmation anybody wants a marker for.
func _note_hits(shooter: DrPlayer, shot: DotShot) -> void:
	if not authoritative or shot == null or shooter == null:
		return
	for damage: DotDamage in shot.damages:
		if damage == null or damage.refused or damage.health_lost <= 0.0 or damage.victim == shooter.entity_id:
			continue
		hit_landed.emit(shooter.player_id, damage.point, damage.lethal, damage.hit_group == DotHitGroup.HEAD)
