extends DotGameCheckSuite

## The wire rig for headless_net: two worlds, two managers, two bridges and the queues between them, and the suite counters. No `class_name`; the suite extends this.

const DrClient := preload("../game/dr_client.gd")
const DrCatalogue := preload("../game/dr_catalogue.gd")
const DrConfig := preload("../game/dr_config.gd")
const DrCourseDoc := preload("../game/dr_course_doc.gd")
const DrEvents := preload("../game/net/dr_events.gd")
const DrGame := preload("../game/dr_game.gd")
const DrNetBridge := preload("../game/net/dr_net_bridge.gd")
const DrPlayer := preload("../game/dr_player.gd")
const DrEvent := preload("../game/net/dr_event.gd")
const DrRequest := preload("../game/net/dr_request.gd")

const CLIENT_PEER := 7
const SESSION := 42
const SERVER_TICK_RATE := 64
const CLIENT_ENGINE_TICK_RATE := 30
const SNAPSHOT_RATE := 30
const INPUT_LEAD := 3
## A second connected player, who must hear nothing of somebody else's hit.
const BYSTANDER_PEER := 8
const BYSTANDER_SESSION := 43

var _sections_entered := 0
var _sections_finished := 0

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
