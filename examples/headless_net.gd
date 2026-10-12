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

const SECTIONS := 9
const CHECKS := 43

const CLIENT_PEER := 7
const SESSION := 42
const SERVER_TICK_RATE := 64
const CLIENT_ENGINE_TICK_RATE := 30
const SNAPSHOT_RATE := 30
const INPUT_LEAD := 3

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


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("deathrun over the wire")
	print("")

	_test_the_codec()

	if await _build():
		await _test_a_client_joins()
		await _test_the_course_arrives()
		await _test_the_local_player_is_predicted()
		await _test_a_press_agrees()
		await _test_a_carry_is_predicted()
		await _test_the_end_crosses()
		await _test_leaving()

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
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(seated.ok, "the server seats them")
	_client_bridge.ask_ready()
	_exchange()
	_exchange()
	await _steps(6)

	_check(_client_bridge.local_player_id == SESSION, "the client is told who it is")
	_check(_client_game.tick_rate == SERVER_TICK_RATE and _client_game.stage.tick_rate == SERVER_TICK_RATE,
		"it adopts the server's tick rate, and so does its course", "%d / %d" % [_client_game.tick_rate, _client_game.stage.tick_rate])
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
			and hand != null and String(hand.get_parent().name) == "arm-right",
		"a watcher draws the weapon in their right hand",
		"%s drawn, %s held, dealt %s" % [
			String(copy.figure.holding) if copy.figure != null else "-",
			String(held_def.id) if held_def != null else "-", str(copy.dealt)
		]
	)

	await _steps(int(_server_game.config.arrival_grace_seconds * SERVER_TICK_RATE) + 4)
	var damage := DotDamage.make(server_me.entity_id, _stand_in.entity_id, 1000.0, null)
	damage.tick = _tick
	var _applied := _server_game.combat.apply_damage(damage)
	await _steps(6)
	_check(_heard.has("round_over") and int(_heard["round_over"][1]) == DrGame.RUNNERS,
		"the runners won, and the client is told", str(_heard.get("round_over")))
	_check(_heard.has("round_over") and str(_heard["round_over"][2]).contains("activator"),
		"with the server's own sentence")
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
