extends Node

const DrCatalogue := preload("../game/dr_catalogue.gd")
const DrConfig := preload("../game/dr_config.gd")
const DrCourseDoc := preload("../game/dr_course_doc.gd")
const DrEvents := preload("../game/net/dr_events.gd")
const DrGame := preload("../game/dr_game.gd")
const DrNetBridge := preload("../game/net/dr_net_bridge.gd")
const DrPlayer := preload("../game/dr_player.gd")
const DrEvent := preload("../game/net/dr_event.gd")
const DrRequest := preload("../game/net/dr_request.gd")

## The real path minus the socket: two worlds, two managers, two bridges, two links with the
## RPC replaced by a queue — so the codec, the seal, the snapshots, the prediction and the
## reconciliation all run, in one process, in two physics worlds.
##
## [b]What this suite is for is the claim the whole game rests on:[/b] a course is sent once,
## as a document, and after that a press is ONE event — a trap and the tick it went on — from
## which the client works out where every part of that trap is at every tick that follows. If
## that is false, a trapdoor the client draws shut is open on the server, and a runner's own
## prediction carries them across a floor that is not there. So this asserts it from both
## ends — the same transform at the same tick, the same answer to "does this kill" — and that a
## client carried by a falling block is carried by its own prediction; and then everything else
## that crosses: the sides, the finish, the end, the result, a joiner told what was pressed.
##
## Sections and checks are both counted; mg-smash-copter's notes say why the second matters.

const SECTIONS := 14
const CHECKS := 69

const CLIENT_PEER := 7
const SESSION := 42
const SERVER_TICK_RATE := 64
const CLIENT_ENGINE_TICK_RATE := 30
const SNAPSHOT_RATE := 30
const INPUT_LEAD := 3
## A second connected player, who must hear nothing of somebody else's hit.
const BYSTANDER_PEER := 8
const BYSTANDER_SESSION := 43

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var _server_game: DrGame = null
var _client_game: DrGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: DrNetBridge = null
var _client_bridge: DrNetBridge = null
var _stand_in: DrPlayer = null

var _to_client: Array = []
var _to_server: Array = []
var _tick: int = 0

## What the client was told, by kind, so a section can ask whether an event arrived.
var _heard: Dictionary = {}
## Every HIT the client's bridge emitted: `[point, killed, headshot]`.
var _hits: Array = []
## Every event the server sent: `[peer_id, kind]`.
var _sent_events: Array = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("deathrun over the wire")
	print("")

	var errors := EngineErrors.new()
	OS.add_logger(errors)

	_test_the_codec()

	if await _build():
		await _test_a_client_joins()
		await _test_the_course_arrives()
		await _test_the_local_player_is_predicted()
		await _test_free_roam_crosses()
		await _test_a_press_agrees()
		await _test_a_carry_is_predicted()
		await _test_the_end_crosses()
		await _test_the_toys_reach_the_client()
		await _test_a_teleport_is_predicted()
		await _test_leaving()

	OS.remove_logger(errors)
	# Engine errors go to stderr and change no exit code: six `!is_inside_tree()` from a toy
	# pulled after its course was rebuilt mid-tick printed on every green run of this suite.
	var seen := errors.seen()
	_check(seen.is_empty(), "the engine reported no error over the whole run",
		"%d: %s" % [seen.size(), ", ".join(seen.slice(0, 3))])

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != SECTIONS:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, SECTIONS
		])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		code = 1

	get_tree().quit(code)


# --- The codec ------------------------------------------------------------------

## Every encoder against its decoder. Nothing checks that two ends of a serialisation are
## inverses for you: dot-moderation once wrote "voice muted" and read back a warning.
func _test_the_codec() -> void:
	_section("every event decodes to what was encoded")

	var hello := DrEvents.read_hello(DotNetReader.new(DrEvents.write_hello(SESSION, 64, 1234, 5.0, 300.0)))
	_check(bool(hello["ok"]) and int(hello["player_id"]) == SESSION
		and absf(float(hello["round_seconds"]) - 300.0) < 0.1
		and absf(float(hello["countdown_seconds"]) - 5.0) < 0.01, "HELLO", str(hello))

	var doc := DrCatalogue.practice()
	var stage := DrEvents.read_stage(DotNetReader.new(DrEvents.write_stage(DrCourseDoc.encode(doc))))
	var decoded := DrCourseDoc.decode(stage["encoded"]) if bool(stage["ok"]) else DotResult.fail(DotError.CODE_PARSE, "no stage")
	_check(decoded.ok and DrCourseDoc.digest(decoded.value) == DrCourseDoc.digest(doc), "STAGE carries the document whole")

	var join := DrEvents.read_join(DotNetReader.new(DrEvents.write_join(SESSION, 9, "Ada", DrGame.ACTIVATORS, null)))
	_check(bool(join["ok"]) and int(join["team"]) == DrGame.ACTIVATORS, "JOIN carries the side", str(join.get("team")))

	var round_info := DrEvents.read_round(DotNetReader.new(DrEvents.write_round(3, false, DrGame.RUNNERS, "the runners got the activator")))
	_check(bool(round_info["ok"]) and int(round_info["winner"]) == DrGame.RUNNERS
		and str(round_info["why"]) == "the runners got the activator", "ROUND carries the winning side and the sentence")

	var finished := DrEvents.read_finished(DotNetReader.new(DrEvents.write_finished(SESSION, 2, 61.25)))
	_check(bool(finished["ok"]) and int(finished["place"]) == 2 and absf(float(finished["seconds"]) - 61.25) < 0.01,
		"FINISHED", str(finished))

	var trap := DrEvents.read_trap(DotNetReader.new(DrEvents.write_trap(4, 98765, SESSION)))
	_check(bool(trap["ok"]) and int(trap["index"]) == 4 and int(trap["tick"]) == 98765 and int(trap["by"]) == SESSION,
		"TRAP carries the trap, the tick it went on, and who", str(trap))

	var clock := DrEvents.read_clock(DotNetReader.new(DrEvents.write_clock(2, 12.5, 40.25, DrGame.Phase.SHOWDOWN, 3, 1, true)))
	_check(bool(clock["ok"]) and int(clock["phase"]) == DrGame.Phase.SHOWDOWN
		and absf(float(clock["run_elapsed"]) - 40.25) < 0.1 and int(clock["runners"]) == 3
		and int(clock["activators"]) == 1, "CLOCK", str(clock))

	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way.
	_check(DrEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [DrEvents.Kind.size(), DrEvent.KIND_BITS])
	_check(DrRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [DrEvents.Ask.size(), DrRequest.KIND_BITS])
	_check(DrEvents.chat_kinds_fit(), "every chat kind fits the chat line's kind field",
		"%d kinds in %d bits" % [DotChatMessage.KIND_NAMES.size(), DrEvents.CHAT_KIND_BITS])

	_finished()


# --- Bringing both halves up ---------------------------------------------------------

func _build() -> bool:
	_section("bringing both halves up")
	var failed_before := _failed

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	# The client's own physics space: two processes would be two worlds, and one world holding
	# both copies of a course is two of every collider in the same cubic metres.
	var client_view := SubViewport.new()
	client_view.name = "ClientView"
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)

	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)
	await get_tree().process_frame

	_check(_server_game.get_world_3d() != _client_game.get_world_3d(), "two physics worlds, as two processes would have")
	_check(_client_game.stage.doc.is_empty() and _client_game.catalogue == null,
		"the client has no course and reads no course files; it will be sent one")

	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE

	_server_net = _make_manager(true, &"server", 1, server_side, SERVER_TICK_RATE)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, CLIENT_ENGINE_TICK_RATE)
	# This harness stamps every command itself (`_tick + INPUT_LEAD`), not from the client's
	# clock, so the client must not ask for dot-net's input-lead report: steered by reports
	# about commands it never stamped, the clock runs away from them (only dot-net's cap
	# holds it). By the constant map, so this parses against a dot-net from before the report.
	var lead_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = DrNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)

	_client_bridge = DrNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var attached := _server_bridge.attach(_server_game, _server_net)
	var client_attached := _client_bridge.attach(_client_game, _client_net)
	_check(attached.ok and client_attached.ok, "both bridges attach")

	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the schema")

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	_client_bridge.rtt_source = func() -> float: return 40.0

	var _s := _server_net.start()
	var _c := _client_net.start()

	_client_bridge.stage_received.connect(func(id: StringName) -> void:
		_heard["stage"] = id)
	_client_bridge.finished_received.connect(func(who: int, place: int, seconds: float) -> void:
		_heard["finished"] = [who, place, seconds])
	_client_bridge.trap_received.connect(func(index: int, tick: int, by: int) -> void:
		_heard["traps"] = int(_heard.get("traps", 0)) + 1
		_heard["trap"] = [index, tick, by])
	_client_bridge.hit_received.connect(func(point: Vector3, killed: bool, headshot: bool) -> void:
		_hits.append([point, killed, headshot]))
	_client_bridge.armed_received.connect(func(who: int, weapon: StringName) -> void:
		_heard["armed_%d" % who] = weapon)
	_client_bridge.round_changed.connect(func(n: int, began: bool, winner: int, why: String) -> void:
		if not began:
			_heard["round_over"] = [n, winner, why])

	_stand_in = _server_bridge.add_bot("Stand-in")
	_check(_stand_in != null and _stand_in.is_bot, "a stand-in is seated before anybody joins")
	# Seated as a stand-in, driven by the suite: a stand-in activator presses traps on its own,
	# and this suite presses them itself, when it wants them.
	_stand_in.is_bot = false

	# Started AFTER the bridge exists, which is what the module does: a course laid out before
	# anything listened to `world_rebuilt` would be a course no client is ever sent.
	_server_game.start()
	_check(not _server_game.stage.doc.is_empty(), "the server lays its course out on start")
	_finished()
	return _failed == failed_before


func _test_a_client_joins() -> void:
	_section("a client joins, and is told its side")
	# The READY first, as over ENet with loss: a client is PLAYING by its own reckoning once it has
	# sent `loaded`, on another channel, so its READY can reach the server before its seat. Kept,
	# and answered by the seat; a bridge that drops it never tells this client who it is.
	_client_bridge.ask_ready()
	_exchange()
	_check(_client_bridge.local_player_id != SESSION, "a READY before the seat is told nothing yet")
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(seated.ok, "the server seats them")
	_exchange()
	_exchange()
	await _steps(6)

	_check(_client_bridge.local_player_id == SESSION, "the client is told who it is")
	_check(_client_game.tick_rate == SERVER_TICK_RATE and _client_game.stage.tick_rate == SERVER_TICK_RATE,
		"it adopts the server's tick rate, and so does its course", "%d / %d" % [_client_game.tick_rate, _client_game.stage.tick_rate])
	_check(Engine.max_physics_steps_per_frame >= ceili(0.25 * float(SERVER_TICK_RATE)),
		"the engine's step cap covers a quarter second at the adopted rate",
		"%d steps for %d Hz" % [Engine.max_physics_steps_per_frame, SERVER_TICK_RATE])
	_check(_client_game.players.size() == 2, "it has a body for itself and for the stand-in", "%d" % _client_game.players.size())

	# Into a round, with the client a runner and the stand-in at the buttons whatever the draw
	# said, and the server's world telling the client so the way a draw does.
	for _i in range(SERVER_TICK_RATE):
		if _server_game.phase == DrGame.Phase.COUNTDOWN:
			break
		await _step()

	_server_game._set_side(DrNetBridge.player_key(SESSION), DrGame.RUNNERS)
	_server_game._set_side(_stand_in.player_id, DrGame.ACTIVATORS)
	_server_game._place_everybody()
	await _steps(6)
	_check(_client_game.team_of(DrNetBridge.player_key(SESSION)) == DrGame.RUNNERS
		and _client_game.team_of(_stand_in.player_id) == DrGame.ACTIVATORS,
		"the client knows who is running and who is at the buttons")
	_finished()


func _test_the_course_arrives() -> void:
	_section("the course arrives, as the document the server built")
	_check(not _client_game.stage.doc.is_empty(), "the client built a course")
	_check(DrCourseDoc.digest(_client_game.stage.doc) == DrCourseDoc.digest(_server_game.stage.doc),
		"the same document, to the byte", DrCourseDoc.digest(_client_game.stage.doc))
	_check(_client_game.stage.pieces.size() == _server_game.stage.pieces.size()
		and _client_game.stage.trap_count() == _server_game.stage.trap_count(),
		"every piece and every trap", "%d, %d" % [_client_game.stage.pieces.size(), _client_game.stage.trap_count()])
	_check(_heard.has("stage"), "and the client said so")
	_finished()


## The course's toys over the wire: paired by index on both ends, frozen copies, and a ball
## kicked on the server followed on the client.
func _test_the_toys_reach_the_client() -> void:
	_section("the course's toys reach the client")
	await _steps(4)
	var count := _server_game.stage.toys.count()
	_check(count > 0 and _server_bridge.toy_count() == count and _client_bridge.toy_count() == count,
		"every toy is an entity on both ends, paired by index", "%d toys, %d and %d" % [count, _server_bridge.toy_count(), _client_bridge.toy_count()])
	var server_ball := _server_game.stage.toys.toy(0)
	var client_ball := _client_game.stage.toys.toy(0)
	_check(client_ball.body.freeze and not client_ball.authoritative, "the client's are frozen copies")
	var start := client_ball.body.global_position
	var _kicked := _server_game.stage.toys.hit(server_ball.body, server_ball.body.global_position, Vector3(-1, 0.2, 0), 2.0)
	await _steps(60)
	var apart := client_ball.body.global_position.distance_to(server_ball.body.global_position)
	_check(client_ball.body.global_position.distance_to(start) > 0.5 and apart < 0.6,
		"a ball kicked on the server is followed on the client, and rests where the server's did",
		"%.2f m moved, %.2f m apart" % [client_ball.body.global_position.distance_to(start), apart])
	_finished()


func _test_the_local_player_is_predicted() -> void:
	_section("the local player is predicted, and the server agrees")
	await _run_open()
	var mine := _mine()
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	server_me.place_at(Vector3(0.0, 0.1, -4.0), 0.0)
	await _steps(20)
	var before := mine.controller.state.position
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _step(forward)
	_check(mine.controller.state.position.distance_to(before) > 0.01,
		"a key moves the client's own player on the tick it is pressed")
	await _steps(24, forward)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "and after running, the two ends agree", "%.3f m" % apart)
	_finished()


## The claim: one event per press, and from it the same trap at every tick on both ends.
func _test_a_press_agrees() -> void:
	_section("a press crosses as one event, and the trap is where the server has it at every tick")
	var heard_before := int(_heard.get("traps", 0))
	var pressed := _server_game.press(2, _stand_in.player_id)
	var pressed_on := _server_game.current_tick()
	await _steps(4)
	_check(pressed and int(_heard.get("traps", 0)) == heard_before + 1, "one TRAP event crossed",
		"%d" % (int(_heard.get("traps", 0)) - heard_before))
	_check(_client_game.stage.fired[2] == pressed_on, "carrying the tick it went on, not the tick it arrived",
		"%d / %d" % [_client_game.stage.fired[2], pressed_on])

	var worst := 0.0
	var agree := 0
	var asked := 0

	for offset in range(0, SERVER_TICK_RATE * 3, 5):
		var tick := pressed_on + offset
		_server_game.stage.pose_at(tick)
		_client_game.stage.pose_at(tick)

		for part_index in range((_server_game.stage.traps[2]["parts"] as Array).size()):
			var a: Node3D = _server_game.stage.traps[2]["parts"][part_index]["node"]
			var b: Node3D = _client_game.stage.traps[2]["parts"][part_index]["node"]
			worst = maxf(worst, a.transform.origin.distance_to(b.transform.origin))

		for at in [Vector3(0.5, 0.0, -27.0), Vector3(-2.5, 0.0, -26.0), Vector3(0.0, 0.0, -24.0)]:
			asked += 1
			if _server_game.stage.lethal_at(at, false, tick) == _client_game.stage.lethal_at(at, false, tick):
				agree += 1

	_check(worst < 0.0001, "the crusher is in the same place on both ends", "worst %.6f m" % worst)
	_check(agree == asked, "and both ends agree about who it kills, every time", "%d of %d" % [agree, asked])

	# A client that asks to be told everything again — a joiner — is told what was pressed.
	_client_game.stage.reset_traps()
	_client_bridge.ask_ready()
	_exchange()
	_exchange()
	await _steps(2)
	_check(_client_game.stage.fired[2] == pressed_on, "a joiner is told every trap already pressed, and when",
		"%d" % _client_game.stage.fired[2])
	_finished()


## Standing on a falling block, the client's own prediction carries them down with it.
func _test_a_carry_is_predicted() -> void:
	_section("a runner on a trap that moves is carried by their own prediction")
	var mine := _mine()
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	server_me.place_at(Vector3(1.0, 0.1, -35.5), 0.0)
	await _steps(30)
	var before := mine.controller.state.position.y
	_check(absf(before) < 0.3, "standing on the block, on the client", "y %.2f" % before)

	var _pressed := _server_game.press(3, _stand_in.player_id)
	var lowest := before

	# The tell, then the fall: trap_tell_seconds of nothing, then the block goes.
	for _i in range(16 + int(_server_game.config.trap_tell_seconds * float(_server_game.tick_rate))):
		await _step()
		lowest = minf(lowest, mine.controller.state.position.y)

	_check(lowest < before - 1.0, "the client's own player went down with it", "lowest y %.2f" % lowest)
	_finished()


func _test_the_end_crosses() -> void:
	_section("the end crosses: the finish, the weapon, the showdown, the result")
	await _wait_for_a_round()
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	server_me.place_at(_server_game.course_doc["finish"]["at"], 0.0)
	await _steps(10)
	_check(_heard.has("finished") and int(_heard["finished"][0]) == SESSION, "the finish is announced, with who")
	_check(_mine().finished and _mine().at_end, "the client's player is across and at the end")
	_check(_heard.has("armed_%d" % SESSION), "and was told what it was handed", str(_heard.get("armed_%d" % SESSION)))
	_check(_client_game.phase == DrGame.Phase.SHOWDOWN, "the client knows the activators were called")

	# The gun in their hand, as somebody else draws it: the client's copy of this player,
	# drawn as a watcher would (not its own first-person view), holds what the server handed.
	var held_def := server_me.weapons.arsenal.current_def() if server_me.weapons != null else null
	var copy := _mine()
	var _shown := copy.present_body(false, copy.global_position, Color.WHITE)
	var hand := copy.figure.attachment(&"right_hand") if copy.figure != null else null
	_check(
		held_def != null and copy.figure != null and copy.figure.holding == held_def.id
			and copy.figure.held != null and copy.figure.held.equipped() == held_def.id
			and hand != null and hand.get_parent() is BoneAttachment3D,
		"a watcher draws the weapon in their hand (the person's gun-hand bone)",
		"%s drawn, %s held, dealt %s" % [
			String(copy.figure.holding) if copy.figure != null else "-",
			String(held_def.id) if held_def != null else "-", str(copy.dealt)
		]
	)

	await _steps(int(_server_game.config.arrival_grace_seconds * SERVER_TICK_RATE) + 4)
	_finished()

	await _test_a_hit_is_the_shooters()

	_section("the showdown's result crosses")
	var damage := DotDamage.make(server_me.entity_id, _stand_in.entity_id, 1000.0, null)
	damage.tick = _tick
	var _applied := _server_game.combat.apply_damage(damage)
	await _steps(6)
	_check(_heard.has("round_over") and int(_heard["round_over"][1]) == DrGame.RUNNERS,
		"the runners won, and the client is told", str(_heard.get("round_over")))
	_check(_heard.has("round_over") and str(_heard["round_over"][2]).contains("activator"),
		"with the server's own sentence")
	_finished()


## The weapon-feel pass's wire half (`DrGame.hit_landed` → HIT → `hit_received`, and the owner-only
## magazine and reserve that `DrClient.correct_drawn` adopts). `headless_run` only proves the
## offline half, where the world's own signal flashes the marker and nothing crosses. Armed: with
## the bridge's HIT send removed the first check fails; sent with `_broadcast` the second does.
func _test_a_hit_is_the_shooters() -> void:
	_section("a shot that lands is told to the shooter alone, and the drawn gun takes the server's count")
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	# A second connected player, READY, so a HIT that went to everybody would reach somebody.
	var _seated := _server_bridge.add_player(BYSTANDER_PEER, BYSTANDER_SESSION, "Bo")
	_server_bridge._admit(BYSTANDER_PEER)
	await _steps(2)

	# Point-blank, straight down the aim: the stand-in three metres in front of the shooter's eye.
	var aim := DotWeaponCommand.new()
	aim.yaw = 0.0
	aim.pitch = 0.0
	var ahead := aim.aim_direction()
	_stand_in.place_at(server_me.global_position + ahead * 3.0, 180.0)
	var full := server_me.weapons.arsenal.current().magazine
	# Hit but never killed: a kill would end the showdown and take the gun this section counts.
	var target_health := _server_game.combat.health_of(_stand_in.entity_id)
	target_health.cannot_die = true
	_hits.clear()
	_sent_events.clear()

	var fire := DotFpsCommand.new()
	fire.yaw = aim.yaw
	fire.pitch = aim.pitch
	fire.set_button(DotFpsCommand.BUTTON_USER_0, true)
	await _steps(3, fire)
	var still := DotFpsCommand.new()
	still.yaw = aim.yaw
	await _steps(INPUT_LEAD + 6, still)

	var to_shooter := _events_of(DrEvents.Kind.HIT, CLIENT_PEER)
	_check(not _hits.is_empty() and to_shooter > 0, "the shooter's bridge is told the shot landed",
		"%d heard, %d sent to the shooter" % [_hits.size(), to_shooter])
	var elsewhere := _events_of(DrEvents.Kind.HIT, BYSTANDER_PEER) + _events_of(DrEvents.Kind.HIT, 0)
	_check(elsewhere == 0, "and nobody else is: no HIT to the other player, none broadcast", "%d" % elsewhere)
	_check(not _hits.is_empty() and (_hits[0][0] as Vector3).distance_to(_stand_in.global_position) < 2.5,
		"at the server's point, on the body that was hit",
		"%s, body at %s" % [str(_hits[0][0]) if not _hits.is_empty() else "-", str(_stand_in.global_position)])

	# Shot back: the shooter is now the victim, and a victim is told nothing (the stand-in has no
	# peer, so a HIT routed by anything but the shooter's session would land on this client).
	_hits.clear()
	_sent_events.clear()
	var shot_back := DotShot.new()
	shot_back.attacker = _stand_in.entity_id
	var wound := DotDamage.make(_stand_in.entity_id, server_me.entity_id, 1.0, null)
	wound.health_lost = 1.0
	wound.point = server_me.global_position + Vector3.UP
	shot_back.damages.append(wound)
	_server_game._note_hits(_stand_in, shot_back)
	await _steps(4, still)
	_check(_hits.is_empty() and _events_of(DrEvents.Kind.HIT, CLIENT_PEER) == 0,
		"a hit somebody else landed on this player is not this player's marker", "%d" % _hits.size())

	# The count: the magazine the server spent arrives in the owner's snapshot fields, and a drawn
	# gun that predicted wrong adopts it once quiet, through the client's own correct_drawn.
	var server_mag := server_me.weapons.arsenal.current().magazine
	var behaviour: Variant = _client_bridge._behaviours.get(SESSION)
	var net_mag := int(behaviour.get(&"net_magazine")) if behaviour != null else -1
	_check(server_mag < full and net_mag == server_mag,
		"the server's magazine, spent, crosses to the owner", "full %d, server %d, client told %d" % [full, server_mag, net_mag])

	var client: Node = (load("res://game/dr_client.gd") as GDScript).new()
	var rig := ZeeWeaponRig.new()
	rig.name = "DrawnForTest"
	rig.role = ZeeWeaponRig.Role.SERVER
	rig.authority = false
	rig.tick_rate = _client_game.tick_rate
	_mine().add_child(rig)
	var _set := rig.setup()
	var held_id := server_me.weapons.current_def().id
	var _given := rig.give(held_id)
	if rig.arsenal.current() == null or rig.arsenal.current_slot() != server_me.weapons.arsenal.current_slot():
		var _picked := rig.arsenal.select(server_me.weapons.arsenal.current_slot(), 0)
	rig.arsenal.current().magazine = rig.arsenal.current().def.magazine
	client.set(&"weapons", rig)
	client.set(&"player", _mine())
	client.set(&"bridge", _client_bridge)
	client.set(&"_offline", false)
	client.set(&"_watch_id", SESSION)
	client.set(&"_drawn_quiet", 0.0)
	var early: bool = client.call(&"correct_drawn")
	var drawn_early := rig.arsenal.current().magazine
	client.set(&"_drawn_quiet", 1.0)
	var corrected: bool = client.call(&"correct_drawn")
	_check(not early and drawn_early != server_mag and corrected and rig.arsenal.current().magazine == server_mag,
		"the drawn gun takes the server's count once quiet, and not before",
		"before %d, after %d, server %d" % [drawn_early, rig.arsenal.current().magazine, server_mag])
	client.free()
	_mine().remove_child(rig)
	rig.free()

	target_health.cannot_die = false
	_server_bridge.remove_peer(BYSTANDER_PEER)
	await _steps(2)
	_finished()


## A trigger volume in the corridor: a runner who walks into it is sent by their own prediction in
## the tick they cross it, and the server, deciding the same from the same position, agrees.
## The pad is added to the server's document and the course laid out again, so it reaches the
## client the way every course does, as the document.
func _test_a_teleport_is_predicted() -> void:
	_section("a teleport is decided by the tick on both ends: the runner lands where the server says")
	var made := DrCourseDoc._piece({
		"kind": "teleport", "at": [0.0, 0.9, -6.0], "size": [3.0, 1.8, 1.0], "to": [-1.5, 0.1, 4.0],
		"heading": 90.0, "solid": false, "for": "runners",
	}, 0)
	var id := StringName(str(_server_game.stage.doc.get("id", "")))
	(_server_game.catalogue.courses[id]["pieces"] as Array).append(made.value)
	_server_game._lay_out_course()
	await _steps(8)
	await _wait_for_a_round()
	var sent := _client_game.stage.teleport_at(Vector3(0.0, 0.1, -6.0))
	_check(sent.size() == 3 and (sent[0] as Vector3).is_equal_approx(Vector3(-1.5, 0.1, 4.0)),
		"the pad arrived with the course, as the same trigger and destination", str(sent))

	var mine := _mine()
	var server_me: DrPlayer = _server_game.players[DrNetBridge.player_key(SESSION)]
	server_me.place_at(Vector3(0.0, 0.1, -2.0), 0.0)
	await _steps(20)
	var warps_before := mine.warps
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _steps(40, forward)
	await _steps(30)
	_check(mine.warps > warps_before, "the client's own tick sent it, not only a snapshot", "%d -> %d" % [warps_before, mine.warps])
	var landed := Vector2(mine.controller.state.position.x + 1.5, mine.controller.state.position.z - 4.0).length()
	_check(landed < 1.0, "and it stands at the destination", "%.2f m from it" % landed)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "where the server has it too", "%.3f m" % apart)
	# The scripted commands here always say yaw 0, so the motor takes the heading back; a real client's
	# sampler is re-aimed (dr_client) and the heading itself is checked in headless_courses. What must hold
	# here is that both ends agree on the facing.
	_check(absf(angle_difference(deg_to_rad(mine.controller.state.yaw), deg_to_rad(server_me.controller.state.yaw))) < 0.2,
		"client and server face the same way after it", "%.1f / %.1f" % [mine.controller.state.yaw, server_me.controller.state.yaw])
	_check(server_me.is_alive(), "and nobody died of the trip")
	_finished()


func _test_free_roam_crosses() -> void:
	_section("free roam is asked for, the server decides, and the mode crosses the wire")
	var spectate := _server_game.spectate
	var rules := _server_game.spectate_rules
	var key := DrNetBridge.player_key(SESSION)
	var me: DrPlayer = _server_game.players[key]
	# The round's clock is held for the section: with the only runner out the traps win and the
	# next round puts the watcher back in play, in the middle of it.
	var held_phase := _server_game.phase
	_server_game.phase = DrGame.Phase.IDLE
	me.watching = true
	spectate.on_died(key, _stand_in.player_id, false, Vector3(0, 2, 0), 0.0, _tick)
	await _steps(SERVER_TICK_RATE * 4)
	_check(spectate.is_spectating(key) and not spectate.is_roaming(key),
		"a watcher starts on a player, not in a free camera", str(spectate.mode_of(key)))
	_check(_client_game.spectate.is_spectating(key), "and the client's mirror is watching too")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(spectate.is_roaming(key), "the server puts a watcher who asks into the free camera")
	_check(_client_game.spectate.is_roaming(key) and _client_game.spectate.is_spectating(key),
		"and the client's mirror is told ROAMING, and still watching")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(key) and not _client_game.spectate.is_roaming(key),
		"the same key hands the camera back to a player on both ends")

	rules.force_camera = 1
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(key), "mp_forcecamera 1 refuses the request")
	rules.force_camera = 0

	rules.allow_roaming = false
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(key) and not _client_game.spectate.is_roaming(key),
		"mp_freeroam 0 refuses it")
	rules.allow_roaming = true

	_client_bridge.ask_roam()
	await _steps(6)
	rules.allow_roaming = false
	await _steps(6)
	_check(not spectate.is_roaming(key) and not _client_game.spectate.is_roaming(key),
		"switching mp_freeroam off mid-roam puts the roamer back on a player on both ends")
	rules.allow_roaming = true
	me.watching = false
	spectate.on_spawned(key)
	_server_game.phase = held_phase
	await _steps(6)
	_finished()


func _test_leaving() -> void:
	_section("leaving")
	_server_bridge.remove_peer(CLIENT_PEER)
	await _steps(4)
	_check(not _server_game.players.has(DrNetBridge.player_key(SESSION)), "the server lets them go")
	_check(not _client_game.players.has(DrNetBridge.player_key(SESSION)) or _server_bridge.describe()["ready_peers"] == 0,
		"and stops talking to them")
	_finished()


# --- Helpers --------------------------------------------------------------------

## How many events of [param kind] the server sent to [param peer_id] (0: broadcast).
func _events_of(kind: int, peer_id: int) -> int:
	var count := 0
	for sent: Array in _sent_events:
		if int(sent[0]) == peer_id and int(sent[1]) == kind:
			count += 1
	return count


func _mine() -> DrPlayer:
	return _client_game.players.get(DrNetBridge.player_key(SESSION))


## Steps until the gate is down.
func _run_open() -> void:
	for _i in range(SERVER_TICK_RATE * 8):
		if _server_game.phase == DrGame.Phase.RUN:
			return
		await _step()


## Steps until a round is running with the client a runner and the stand-in at the buttons —
## the carry section's death ended the last one.
func _wait_for_a_round() -> void:
	for _i in range(SERVER_TICK_RATE * 10):
		if _server_game.phase == DrGame.Phase.COUNTDOWN:
			break
		await _step()

	_server_game._set_side(DrNetBridge.player_key(SESSION), DrGame.RUNNERS)
	_server_game._set_side(_stand_in.player_id, DrGame.ACTIVATORS)
	_server_game._place_everybody()
	await _run_open()


func _make_game(server: bool, parent: Node) -> DrGame:
	var config := DrConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.arrival_grace_seconds = 0.2
	config.minimum_players = 0
	config.keep_progress = false
	config.course_ids = PackedStringArray(["dr_practice"])

	var game := DrGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = server
	game.tick_rate = SERVER_TICK_RATE if server else CLIENT_ENGINE_TICK_RATE
	game.register_service = false
	parent.add_child(game)
	game.set_physics_process(false)
	return game


func _make_manager(server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	config.world_extent = DrGame.NET_WORLD_EXTENT
	manager.config = config

	parent.add_child(manager)
	var _ready_now := manager.setup()
	return manager


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	# Every event the server sends, by who it was for, decoded with the client's own registry:
	# what "to the shooter alone" is checked against, the bystander's included.
	if method == &"event":
		var decoded := _client_net.messages.decode(DotNetReader.new(payload), 1, false)
		if decoded.ok and decoded.value is DrEvent:
			_sent_events.append([peer_id, (decoded.value as DrEvent).kind])

	if peer_id != 0 and peer_id != CLIENT_PEER:
		return

	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


func _exchange() -> void:
	_flush()
	_flush()


## One tick on both ends, with a real physics frame between them.
func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	var _ticks := _client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		await _step(command)


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)


## Counts the engine's own errors while installed (mg-smash-copter's dedicated suite has the
## same class): they go to stderr and change no exit code, so only this makes one fail a run.
class EngineErrors extends Logger:
	var _lock := Mutex.new()
	var _seen := PackedStringArray()

	func _log_error(
		function: String, _file: String, _line: int, code: String, _rationale: String,
		_editor_notify: bool, _error_type: int, _script_backtraces: Array[ScriptBacktrace]
	) -> void:
		_lock.lock()
		_seen.append("%s (%s)" % [code, function])
		_lock.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

	func seen() -> PackedStringArray:
		_lock.lock()
		var out := _seen.duplicate()
		_lock.unlock()
		return out
