extends Node

const DrEvent := preload("dr_event.gd")
const DrEvents := preload("dr_events.gd")
const DrNetCommand := preload("dr_net_command.gd")
const DrNetLink := preload("dr_net_link.gd")
const DrPlayerNet := preload("dr_player_net.gd")
const DrToyNet := preload("dr_toy_net.gd")
const DrRequest := preload("dr_request.gd")

const DrGame := preload("../dr_game.gd")
const DrCourseDoc := preload("../dr_course_doc.gd")
const DrPlayer := preload("../dr_player.gd")

## Joins an [DrGame] to a [DotNetManager]. The netcode seam, and the only file in this
## project that names both.
##
## [codeblock]
## # server
## bridge.attach(game, net)          # dot-game's DotGameNetcode does this
## bridge.open_link(server)          # and this
## bridge.add_player(peer_id, userid, "Ada")
## bridge.server_tick(tick)          # instead of the game's own loop
##
## # client
## bridge.attach(game, net)
## bridge.open_link(client_link)
## bridge.ask_ready()
## bridge.client_tick(tick, command, slot)
## [/codeblock]
##
## [b]What crosses.[/b] A player's own movement is predicted, like every first-person game in
## this family. The course arrives ONCE, as a document in `STAGE`, and after that the only
## thing about it that is ever sent is a press: `TRAP`, a trap and the tick it went on. Every
## part of every trap is a function of that tick and the current one (see [DrCourse]), so a
## client predicting tick N poses the course at tick N itself and gets the server's answer
## without being told it.
##
## [b]The ordering is the other half of the file.[/b] dot-net drives simulation per entity;
## this game's tick is a whole-world property — the course is posed, every player moves, then
## the buttons, the traps and the finish are decided. [method ensure_game_ticked] reconciles the
## two: the first behaviour through on a tick runs the whole world and the rest find it done.

const CHANNEL := "dr.net"

## Bytes of acknowledgement in front of every input packet. [method DotNetManager.encode_ack].
const ACK_BYTES := 4

## Commands in every input packet: this tick's and the four before it, so a lost packet
## costs the server no tick unless the next four are lost too. Over WebSocket nothing is
## ever lost; over ENet (the desktop client, since servers went dual-stack) one command a
## packet was a tick the server ran on the previous command for every packet dropped.
## game-arena measured it first: 80% of ticks with the right command at 20% loss with one
## copy, 99-100% with three, and five closed the rest (2026-10-09).
const INPUT_COPIES := 5

## How often the round clock and the numbers behind it go out, in ticks.
##
## [b]Twice a second, not per tick and not per snapshot.[/b] What it carries changes when
## somebody finishes or a second passes, and a client told sixty-four times a second would be
## paying for sixty-two copies of the same numbers. The clock itself is advanced on the
## client between messages — see [method _apply_clock].
const CLOCK_EVERY := 32

## The client has been told who it is. [param player_id] is the session id.
signal hello_received(player_id: int)

## Somebody joined, left or changed sides. Client side; the HUD and a scoreboard read it.
signal roster_changed(player_id: int)

## A round began or ended. [param why] is the server's sentence about who won.
signal round_changed(number: int, began: bool, winner: int, why: String)

## The round changed half. Client side.
signal phase_received(phase: int)

## Somebody died, and what did it.
signal death_received(player_id: int, by: int, why: StringName)

## Somebody was handed, or picked up, a weapon. The HUD names it.
signal armed_received(player_id: int, weapon_id: StringName)
## Your shot landed (see [signal DrGame.hit_landed]); only ever to the shooter.
signal hit_received(point: Vector3, killed: bool, headshot: bool)

signal notice_received(text: String)

## Client side: the server moved this client's own camera. [param mode] is
## [enum DotSpectatorView.Mode]; the view has already been adopted by the world's mirror.
signal spectate_received(viewer: int, mode: int, target: int)

## Client side: somebody else used their weapon [param times] times since the last
## snapshot. [param kind] is one of `ZeeWeaponNet.KIND_*`. Relayed from that player's own
## behaviour, because a client builds those one per JOIN and nothing else could find them.
signal weapon_used_by(session_id: int, times: int, kind: int)

## Client side: the course was rebuilt from what the server sent. The HUD names it.
signal stage_received(stage_id: StringName)

## Client side: a runner reached the end.
signal finished_received(player_id: int, place: int, seconds: float)

## Client side: a trap was pressed, on [param tick], by [param by] (a session, 0 for nobody).
## The world has already been told; this is for the speakers and the screen.
signal trap_received(index: int, tick: int, by: int)

## Somebody pressed Enter. Server side, and the only thing this bridge does with chat.
##
## [b]The bridge carries chat and decides nothing about it.[/b] Who may say what, on which
## channel, how often and who hears it are [DotChatRouter]'s, and the router is the services
## layer's.
signal say_requested(peer_id: int, channel_id: StringName, text: String)

## A voice frame arrived. Server side; the payload is unparsed and must not be trusted —
## [method DotVoiceRouter.relay] is what stamps the speaker, from the peer id below.
signal voice_requested(peer_id: int, payload: PackedByteArray)

## Client side: one routed line, and one voice frame.
signal chat_received(wire: Dictionary)
signal voice_arrived(payload: PackedByteArray)

var game: DrGame = null
var net: DotNetManager = null
var link: DrNetLink = null

## Which session this process is. Zero on a server.
var local_player_id: int = 0

## Where the clock learns how long the link is, in milliseconds.
##
## dot-net never touches a transport and cannot measure it; dot-server's heartbeat already
## does ([method DotClientLink.ping_ms]). A client that feeds nothing has a clock that
## assumes an instant connection and stamps every command for a tick the server has already
## simulated — and the symptom is every command being discarded as late. Two games in this
## family shipped without a sample and read a median of an empty set.
var rtt_source: Callable = Callable()

## Where a voice frame goes on the server. Assigned by [DotGameModule] to the services
## layer's `relay_voice`, because the bridge is the only thing that names both ends.
var voice_relay_fn: Callable = Callable()

## `func(session_id: int) -> DotAvatar`: what a player looks like, asked once as they are
## seated. Assigned by the module, which is what has the identity layer; unset, or answering
## null, is the stock person, which is what everybody was before there was one.
var avatar_fn: Callable = Callable()

var _entities: Node = null

## session id -> [DrPlayerNet].
var _behaviours: Dictionary = {}

## The next session id handed to somebody the world made itself.
##
## [b]Well above anything dot-server will issue, and a bot needs one at all because of how a
## player id is written.[/b] Every id on the wire is `u<session>`, and a player called `bot`
## parses back to session ZERO — so two bots are one entry in [member _behaviours], and
## their JOIN carries a player id that is also dot-net's broadcast address.
const FIRST_BOT_SESSION := 900000

var _next_bot_session: int = FIRST_BOT_SESSION

var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
## Server: peers whose READY came before their seat ([method add_player]). A client sends READY
## when its link says PLAYING, which the link decides itself after sending `loaded` on another
## channel; over ENet with loss the READY can overtake `loaded`, and a READY dropped here left
## that client waiting for a world for ever. Admitted when seated.
var _ready_unseated: Dictionary = {}

var _tick: int = 0
var _game_ticked_for: int = -1

## Server only: whether [method DotNetManager.server_tick] is on the stack, and the net ids
## let go of while it was.
##
## [b]An entity let go of mid-tick leaks a lag-compensation track, for ever.[/b]
## mg-smash-copter's finding: the world ticks inside the first player behaviour's
## `_net_simulate`, so a player removed there is unregistered while `server_tick` is still
## holding the identity list it took before simulating — and then records history for it. The registry has
## already told the history to forget each id; the record makes a fresh track for it again,
## and nothing ever forgets it a second time.
## Forgotten again here once the manager has let go of its list.
var _in_server_tick := false
var _unregistered_in_tick: Array[int] = []
var _client_ticked_for: int = -1

## The stage the clients were last sent, so a late joiner is sent the same bytes.
var _stage_body: PackedByteArray = PackedByteArray()


# --- Wiring ----------------------------------------------------------------

## [param p_game] and [param p_net], in the shape [DotGameNetcode] calls it.
func attach(p_game: Object, p_net: DotNetManager) -> DotResult:
	var world := p_game as DrGame

	if world == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs a world and a manager.")

	if world.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The world and the manager disagree about who is authoritative.",
			"world=%s net.is_server=%s" % [world.authoritative, p_net.is_server]
		)

	game = world
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	net.send_fn = _send

	var event := net.messages.register(
		DrEvent.NAME, DrEvent,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)

	if not event.ok:
		return event

	var request := net.messages.register(
		DrRequest.NAME, DrRequest,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)

	if not request.ok:
		return request

	net.messages.on(DrEvent.NAME, _on_event)
	net.messages.on(DrRequest.NAME, _on_request)

	# Both ends. The server's tick is `server_tick` and the client's is `client_tick`, which
	# simulates what it predicts and leaves the rest to interpolation. A world still running
	# its own `_physics_process` would move every player twice.
	game.external_tick = true

	# The course's toys: the server's leave the registry before their nodes go and the new ones
	# are named after STAGE; a client's mirrors stay registered and are handed this end's toys
	# when its course is built.
	if net.is_server:
		game.world_clearing.connect(_release_toys)
	else:
		game.world_clearing.connect(_unpair_toys)
		game.world_rebuilt.connect(_pair_pending_toys)

	if net.is_server:
		game.player_added.connect(_on_player_added)
		game.player_removed.connect(_on_player_removed)
		game.world_rebuilt.connect(_on_world_rebuilt)
		game.round_began.connect(_on_round_began)
		game.round_over.connect(_on_round_over)
		game.phase_changed.connect(_on_phase_changed)
		game.player_died.connect(_on_player_died)
		game.side_changed.connect(func(id: StringName, side: int) -> void:
			_broadcast(DrEvents.Kind.TEAM, DrEvents.write_team(session_of(id), side))
		)
		game.player_finished.connect(func(id: StringName, place: int, seconds: float) -> void:
			_broadcast(DrEvents.Kind.FINISHED, DrEvents.write_finished(session_of(id), place, seconds))
		)
		game.trap_fired.connect(func(index: int, tick: int, by: StringName) -> void:
			_broadcast(DrEvents.Kind.TRAP, DrEvents.write_trap(
				index, tick, session_of(by) if by != &"" else 0))
		)
		# Here and not in the module, which is where mg-wipeout wired it: the net suite has no
		# module, and an end arena whose handout reached nobody passed every other check.
		game.player_armed.connect(announce_armed)
		# To the shooter alone: a hit marker is that player's business.
		game.hit_landed.connect(func(id: StringName, point: Vector3, killed: bool, headshot: bool) -> void:
			var hit_peer := peer_for_player(session_of(id))
			if hit_peer > 0:
				_tell(hit_peer, DrEvents.Kind.HIT, DrEvents.write_hit(point, killed, headshot)))
		# To the one who pressed, never broadcast: a refusal is that person's business.
		game.button_refused.connect(func(id: StringName, why: String) -> void:
			var peer_id := peer_for_player(session_of(id))
			if peer_id > 0:
				notice(peer_id, why)
		)

		if game.spectate != null:
			game.spectate.view_changed.connect(_on_spectate_changed)

		_wire_lag_compensation()

	return DotResult.success(true)


## Hands dot-combat the two callables that make lag compensation real.
##
## [b]Two lines, and without them the setting is a lie.[/b] dot-combat names no dot-net type
## — the whole point of the seam — so it takes a rewind and a restore as [Callable]s and,
## unset, says so once at boot and then resolves every shot against the present anyway. A
## game that left the flag on and the callables unset would report lag compensation as
## enabled, do nothing, and cost the next reader an afternoon; this family calls that
## "produced correctly and consumed by nothing" and it is its second most repeated bug.
##
## dot-net already records the history: `DotNetManager.server_tick` calls
## `history.record(identities, tick)` once a snapshot. There is nothing to build.
##
## [b]The shooter is not excluded, and that is safe here rather than an oversight.[/b]
## `DotNetHistory.rewind` can leave one entity alone so that rewinding does not move the
## shooter's own muzzle — but `resolve_shot` fixes `shot.origin` before it rewinds anything,
## so the muzzle has already been decided, and the resolver refuses self damage separately.
## What excluding would buy is one fewer entity moved and put back.
func _wire_lag_compensation() -> void:
	if game.combat == null or net == null:
		return

	if game.combat.config != null:
		game.combat.config.lag_compensation = true

	game.combat.rewind_fn = func(target_tick: float) -> void:
		var _rewound := net.history.rewind(
			net.registry.all(), int(target_tick), net.clock.tick
		)

	game.combat.restore_fn = func() -> int:
		return net.history.restore()

	DotLog.debug(CHANNEL, "lag compensation is wired to the netcode's history", {
		"max_rewind_ms": game.combat.config.max_rewind_ms if game.combat.config != null else 0.0,
	})


## Opens the link under [param parent], whose NAME is half the RPC routing.
##
## A [DotServer] on one end and a [DotClientLink] on the other, both called `Server`, with
## this node under each: Godot routes an RPC by the receiver's node path, so a link opened
## anywhere else is addressed by a path the other end does not have and every message lands
## nowhere, with no error on either side.
func open_link(parent: Node) -> void:
	if parent == null or link != null:
		return

	link = DrNetLink.attached_to(parent, self, net != null and net.is_server)
	# Not parent.add_child: the link sits under the server (RPCs route by path) but must die
	# with this bridge. A bare add_child left a second link after a module reload and Godot
	# renamed the live one `@Node@n`, so RPCs to clients were lost. DotGameLink frees it with
	# the bridge without remove_child, which errors on a busy parent.
	DotGameLink.attach(link, parent, self, DrNetLink.NODE_NAME)


## How every dot-net message reaches a peer.
##
## [b]Routed by DELIVERY, not by kind.[/b] Snapshots are unreliable and go on the snapshot
## call; everything else is reliable, and which reliable call it is depends on which end is
## sending — the server has events, the client has requests. Sending them all as events
## works on a server and silently drops every client request, which is a client that
## connects, draws, and can never ask for anything.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


# --- Identity --------------------------------------------------------------

static func player_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


static func session_of(id: StringName) -> int:
	return String(id).trim_prefix("u").to_int()


func peer_for_player(session_id: int) -> int:
	return int(_peer_of_player.get(session_id, 0))


func player_for_peer(peer_id: int) -> int:
	return int(_player_of_peer.get(peer_id, 0))


# --- Server: players -------------------------------------------------------

## Puts a connected peer into the game. What [DotGameRoster] calls.
func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	if peer_id > 0:
		# FIRST, because `game.add_player` emits `player_added` and the handler has to be
		# able to find which peer this player belongs to.
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	var player := game.add_player(player_key(session_id), display_name)

	if player == null:
		_player_of_peer.erase(peer_id)
		_peer_of_player.erase(session_id)
		return DotResult.fail(DotError.CODE_STATE, "The game refused the player.")

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		_admit(peer_id)

	return DotResult.success(player)


## Somebody the world drives itself: a stand-in, or a test's player.
##
## [b]The same entity a peer gets, with a peer id of zero.[/b] A bot is replicated, scored
## and crushed exactly like a person — what it does not have is a socket — and that is the
## whole of the difference.
func add_bot(display_name: String, team: int = 0) -> DrPlayer:
	if net == null or not net.is_server or game == null:
		return null

	var session_id := _next_bot_session
	_next_bot_session += 1

	var player := game.add_player(player_key(session_id), display_name, team)

	if player == null:
		return null

	player.is_bot = true
	return player


func remove_peer(peer_id: int) -> void:
	_ready_unseated.erase(peer_id)

	if _player_of_peer.has(peer_id):
		remove_player(int(_player_of_peer[peer_id]))


## Removes a player whether or not a peer is behind it — a bot has none.
func remove_player(session_id: int) -> void:
	if not _behaviours.has(session_id):
		return

	var peer_id := peer_for_player(session_id)
	var was_ready := _ready_peers.has(peer_id)

	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)

	# Released BEFORE the game is told: `game.remove_player` emits `player_removed`, which
	# `_on_player_removed` answers by releasing the entity and broadcasting the LEAVE.
	# Releasing first empties `_behaviours`, so that handler finds nothing and this stays
	# the one place a leaving player is announced.
	_release_entity(session_id)
	game.remove_player(player_key(session_id))

	if net != null and peer_id > 0:
		if was_ready:
			net.remove_peer(peer_id)

		if net.interest != null:
			net.interest.forget_peer(peer_id)

	_broadcast(DrEvents.Kind.LEAVE, DrEvents.write_player(session_id))
	roster_changed.emit(session_id)


func _on_player_added(id: StringName) -> void:
	if net == null or not net.is_server:
		return

	var session_id := session_of(id)

	if _behaviours.has(session_id):
		return

	# [b]Every id on the wire is `u<session>`, and anything else parses back to zero.[/b] A
	# world that added a player called `bot` would replicate it under session 0 — which is
	# also dot-net's broadcast address — and a second one would silently replace the first
	# in this table. Refused with a line rather than accepted quietly: the symptom otherwise
	# is one stand-in playing and the other standing still for ever.
	if player_key(session_id) != id:
		DotLog.warn(CHANNEL, "a player whose id is not a session key is not replicated", {
			"id": String(id), "hint": "use add_bot() or DrNetBridge.player_key()",
		})
		return

	var player: DrPlayer = game.players.get(id)

	if player == null:
		return

	var identity := _build_entity(player, peer_for_player(session_id))
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a player", {"error": str(registered.error)})
		return

	# Before the JOIN, so the first thing anybody hears about this person is their face.
	if player.avatar == null and avatar_fn.is_valid():
		var avatar: Variant = avatar_fn.call(session_id)
		player.avatar = avatar as DotAvatar if avatar is DotAvatar else null

	_broadcast(DrEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)


func _on_player_removed(id: StringName) -> void:
	var session_id := session_of(id)

	if _behaviours.has(session_id):
		# The game removed them itself; the entity and the LEAVE are still ours.
		_release_entity(session_id)
		_broadcast(DrEvents.Kind.LEAVE, DrEvents.write_player(session_id))
		roster_changed.emit(session_id)


func _build_entity(player: DrPlayer, peer_id: int) -> DotNetIdentity:
	# The behaviour is added BEFORE the identity: [DotNetIdentity] collects behaviours in
	# `_ready` by walking the subtree, and one added afterwards would never be found.
	var behaviour := DrPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. SERVER would put a player's own
	# movement a round trip behind their keys, which on a course is the difference between
	# clearing an arm and being told it already hit you.
	identity.authority = DotNetIdentity.Authority.SHARED
	# [b]Always, and the map is why.[/b] Interest management is a saving where most players
	# are out of sight; a course is open air with nothing taller than a gantry on it, so
	# everybody can see everybody and culling would only ever produce a runner who vanishes
	# in mid-jump.
	identity.always_relevant = true
	player.add_child(identity)

	var session_id := session_of(player.player_id)
	_behaviours[session_id] = behaviour

	# Only ever emitted on a mirror, where the snapshot is what says a weapon was used.
	behaviour.weapon_used.connect(func(times: int, kind: int) -> void:
		weapon_used_by.emit(session_id, times, kind)
	)
	return identity


## Server side. See [member _in_server_tick] for why an id let go of mid-tick is remembered.
func _unregister(net_id: int) -> void:
	net.registry.unregister(net_id)

	if _in_server_tick:
		_unregistered_in_tick.append(net_id)


func _release_entity(session_id: int) -> void:
	var behaviour: DrPlayerNet = _behaviours.get(session_id)
	_behaviours.erase(session_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	_unregister(behaviour.identity.net_id)


# --- Server: the world -----------------------------------------------------

## A new course: the whole document, to everybody, before anything that stands on it.
func _on_world_rebuilt() -> void:
	if net == null or not net.is_server or game.stage == null or game.stage.doc.is_empty():
		return

	_stage_body = DrEvents.write_stage(DrCourseDoc.encode(game.stage.doc))
	_broadcast(DrEvents.Kind.STAGE, _stage_body)
	_register_toys()


# --- Both ends: the course's toys ---------------------------------------------------

## The course's toys on the wire, one behaviour per toy in toy order, and the TOYS event that names
## their net ids (kept for a joiner).
var _toy_nets: Array = []
var _toys_body: PackedByteArray = PackedByteArray()

## Client: which map the last TOYS was for. Its mirrors are registered at once and handed their
## toys when this end's toys for that course exist ([method _pair_pending_toys]).
var _toys_map: StringName = &""

## Client: where the mirrors live, which is not under the toys: a client registers them the
## moment TOYS arrives, before its own map may be built, and keeps them through a map change.
var _toy_holder: Node3D = null


## Server: an entity for each of the course's toys, and TOYS naming them.
func _register_toys() -> void:
	if net == null or not net.is_server or game == null:
		return
	_release_toys()
	var ids := PackedInt64Array()
	if game.stage != null and game.stage.toys != null:
		for toy in game.stage.toys.toys:
			var behaviour := _toy_entity(toy, toy, 0)
			if behaviour == null:
				break
			ids.append(behaviour.identity.net_id)
	_toys_body = DrEvents.write_toys(game.stage.id() if game.stage != null else &"", ids)
	_broadcast(DrEvents.Kind.TOYS, _toys_body)


## A toy's behaviour and identity under [param parent], registered under [param net_id] (0
## allocates: the server); null when the registry refused it. The behaviour before the
## identity, which collects behaviours in its `_ready`.
func _toy_entity(toy: DotPropToy, parent: Node, net_id: int) -> DrToyNet:
	var behaviour := DrToyNet.new()
	behaviour.name = "Net"
	behaviour.toy = toy
	var holder := Node3D.new() if parent != toy else null
	if holder != null:
		holder.name = "Toy%d" % _toy_nets.size()
		parent.add_child(holder)
	var at: Node = holder if holder != null else toy
	at.add_child(behaviour)
	if net.is_server:
		behaviour.pull()
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	at.add_child(identity)
	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a toy", {"toy": _toy_nets.size(), "error": str(registered.error)})
		at.remove_child(behaviour)
		at.remove_child(identity)
		behaviour.queue_free()
		identity.queue_free()
		if holder != null:
			parent.remove_child(holder)
			holder.queue_free()
		return null
	_toy_nets.append(behaviour)
	return behaviour


## Every toy entity out of the registry and out of the tree at once: a new identity on the same
## toy collects every behaviour under it in its `_ready`, and a freed one found there broke the
## next snapshot. The server's, on a map change or a new set.
func _release_toys() -> void:
	for behaviour: DrToyNet in _toy_nets:
		if not is_instance_valid(behaviour):
			continue
		if behaviour.identity != null and net != null and net.registry.has(behaviour.identity.net_id):
			if net.is_server:
				_unregister(behaviour.identity.net_id)
			else:
				net.registry.unregister(behaviour.identity.net_id)
		var at := behaviour.get_parent()
		for node: Node in [behaviour.identity, behaviour]:
			if node != null and is_instance_valid(node) and node.get_parent() != null:
				node.get_parent().remove_child(node)
				node.queue_free()
		if at != null and at.get_parent() == _toy_holder and _toy_holder != null:
			_toy_holder.remove_child(at)
			at.queue_free()
	_toy_nets.clear()


## Client, on TOYS: a mirror for every id at once, under the holder, whether this end's toys
## for that course exist yet or not. [b]A client must know every entity a snapshot carries[/b]:
## dot-net stops reading a snapshot at the first one it does not know (a body cannot be skipped
## without its declarations), so a toy mirror missing while the client loads the map, or ever,
## on a client left on another map, was every player after it frozen. Paired with its toy
## by index as soon as both are here.
func _apply_toys(told: Dictionary) -> void:
	if net == null or net.is_server:
		return
	_release_toys()
	if _toy_holder == null:
		_toy_holder = Node3D.new()
		_toy_holder.name = "ToyMirrors"
		add_child(_toy_holder)
	_toys_map = told["map_id"]
	for id in (told["ids"] as PackedInt64Array):
		var _mirror := _toy_entity(null, _toy_holder, int(id))
	_pair_pending_toys()


## Client: each mirror handed this end's toy at its index, once this end's toys are for the map
## TOYS named; none while they are not (a map change on the way, or another map).
func _pair_pending_toys() -> void:
	if net == null or net.is_server or game == null:
		return
	var box := game.stage.toys if game.stage != null and game.stage.toys != null and game.stage.id() == _toys_map else null
	if box != null and box.count() != _toy_nets.size():
		DotLog.warn(CHANNEL, "the server's map has a different number of toys", {"server": _toy_nets.size(), "here": box.count()})
	for i in range(_toy_nets.size()):
		var behaviour: DrToyNet = _toy_nets[i]
		behaviour.toy = box.toy(i) if box != null else null


## Client: the old course's toys are about to go; the mirrors stay registered, without them.
func _unpair_toys() -> void:
	for behaviour: DrToyNet in _toy_nets:
		if is_instance_valid(behaviour):
			behaviour.toy = null


## How many toys this end replicates (a client: mirrors paired with a toy). For a check.
func toy_count() -> int:
	var n := 0
	for behaviour: DrToyNet in _toy_nets:
		if is_instance_valid(behaviour) and (net.is_server or behaviour.toy != null):
			n += 1
	return n


# --- Server: the round -----------------------------------------------------

func _on_round_began(number: int, _layout_id: StringName) -> void:
	_broadcast(DrEvents.Kind.ROUND, DrEvents.write_round(number, true, 0))


func _on_round_over(number: int, winner: int, why: String) -> void:
	_broadcast(DrEvents.Kind.ROUND, DrEvents.write_round(number, false, winner, why))


func _on_phase_changed(phase: int) -> void:
	_broadcast(DrEvents.Kind.PHASE, DrEvents.write_phase(phase))


func _on_player_died(player_id: StringName, by: StringName, why: StringName) -> void:
	var who: DrPlayer = game.players.get(player_id) if game != null else null
	_broadcast(DrEvents.Kind.DEATH, DrEvents.write_death(
		session_of(player_id), session_of(by) if by != &"" else 0, why,
		who.death if who != null else null
	))


## A view changed on the server. Told to its owner and to nobody else.
##
## [b]To the one peer, because a camera is private.[/b] Who somebody is watching is a fact
## about them that nobody else has any business knowing — and a stand-in, whose peer is
## zero, is told nothing, which `_tell` guarantees rather than this.
func _on_spectate_changed(player_id: StringName) -> void:
	if game == null or game.spectate == null or game.spectate.manager == null:
		return

	var session_id := session_of(player_id)
	var peer_id := peer_for_player(session_id)

	if peer_id <= 0 or not _ready_peers.has(peer_id):
		return

	var view := game.spectate.manager.view(String(player_id))
	var target := session_of(StringName(view.target)) if view.target != "" else 0
	var killer := session_of(StringName(view.killer)) if view.killer != "" else 0

	_tell(peer_id, DrEvents.Kind.SPECTATE, DrEvents.write_spectate(
		session_id, int(view.mode), target, killer, view.death_position
	))


## Says what somebody was handed.
func announce_armed(player_id: StringName, weapon_id: StringName) -> void:
	_broadcast(DrEvents.Kind.ARMED, DrEvents.write_armed(session_of(player_id), weapon_id))


# --- Server: the tick ------------------------------------------------------

func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1

	if net != null:
		_in_server_tick = true
		net.server_tick(tick)
		_in_server_tick = false

		for net_id in _unregistered_in_tick:
			if not net.registry.has(net_id):
				net.history.forget(net_id)

		_unregistered_in_tick.clear()

	# Belt and braces: `net.server_tick` drives the entities, and the first player behaviour
	# through calls `ensure_game_ticked`. A server with nobody on it has no behaviours at
	# all, and a world that only ticked when somebody was connected is a server whose round
	# clock stops between players — which looks like the server having hung.
	ensure_game_ticked(tick)

	if tick % CLOCK_EVERY == 0:
		_broadcast(DrEvents.Kind.CLOCK, _clock_body())


func _clock_body() -> PackedByteArray:
	return DrEvents.write_clock(
		game.round_number,
		game.phase_elapsed,
		game.run_elapsed,
		game.phase,
		game.alive_on(DrGame.RUNNERS),
		game.alive_on(DrGame.ACTIVATORS),
		game.sides_are_playable()
	)


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return

	_game_ticked_for = tick

	for session_id in _behaviours:
		var behaviour: DrPlayerNet = _behaviours[session_id]

		# Only what a peer sent. A bot has no peer and is driven by the game itself, and an
		# empty command applied over the top of that would stand it still.
		if behaviour.player != null and behaviour.identity != null \
				and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())
			behaviour.player.wanted_slot = behaviour.last_slot
			behaviour.player.wants_use = behaviour.last_use

	game.tick_once(tick)

	# The toys where the physics left them, before the snapshot.
	for behaviour: DrToyNet in _toy_nets:
		behaviour.pull()

# --- The client tick -------------------------------------------------------

func client_tick(tick: int, command: DotFpsCommand, slot: int = 0, use: bool = false) -> void:
	if net == null or net.is_server or game == null:
		return

	_tick = tick

	var packet := DrNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()
	packet.slot = slot
	packet.use = use

	# Into the local history BEFORE predicting: reconciliation replays it.
	net.local_inputs().push(packet)

	# The behaviour simulates from `last_move` on a fresh tick and on a replayed one alike —
	# the predictor's replay sets it through `_net_apply_input`, and this is the fresh tick's
	# equivalent.
	var mine: DrPlayerNet = _behaviours.get(local_player_id)

	if mine != null:
		mine.last_move = packet.move
		mine.last_slot = slot
		mine.last_use = use

		if mine.player != null:
			mine.player.wanted_slot = slot

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		DotNetInput.write_batch(writer, _input_copies(packet))
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	# One predicted player, and nothing else: everybody else is drawn from snapshots, and the
	# course is posed by the predicted player's own controller at each tick it simulates.
	if _client_ticked_for != tick:
		_client_ticked_for = tick

		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				behaviour._net_simulate(tick, net.clock.tick_duration())

		# The clock a client shows, advanced between the twice-a-second messages that
		# correct it. Without this the round timer ticks in half-second steps.
		game.phase_elapsed += net.clock.tick_duration()

		if game.phase == game.Phase.RUN or game.phase == game.Phase.SHOWDOWN:
			game.run_elapsed += net.clock.tick_duration()


# --- Receiving -------------------------------------------------------------

func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	return net.receive_snapshot(payload)


## [param packet] and the commands before it from the local replay history, oldest first,
## for one input packet. See [constant INPUT_COPIES].
func _input_copies(packet: DotNetInput) -> Array:
	var batch: Array = Array(net.local_inputs().recent(INPUT_COPIES, packet.tick - 1))
	batch = batch.slice(maxi(0, batch.size() - (INPUT_COPIES - 1)))
	batch.append(packet)
	return batch


func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")

	if not _player_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	# A batch: this tick's command and the ones before it (see [constant INPUT_COPIES]).
	# Copies of ticks already simulated are skipped rather than pushed, or each would count
	# as a late input; the packet's own tick is always pushed, so a late one still counts.
	var batch := DotNetInput.read_batch(
		DotNetReader.new(payload.slice(ACK_BYTES)),
		func() -> DotNetInput: return DrNetCommand.new()
	)
	if batch.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "Input packet carries no command.")
	var buffer := net.input_buffer_for(peer_id)
	var newest := batch[batch.size() - 1]
	var pushed := DotResult.success(false)
	for input in batch:
		if input != newest and input.tick <= buffer.last_consumed_tick():
			continue
		pushed = buffer.push(input)
	return pushed


## Text for one player: a refusal, a rate limit, a command's reply.
##
## [b]To the one person who asked, and that is the whole reason this is a method.[/b] "You
## are talking too fast" and "you are gagged" are the two commonest things a server says,
## and both are nobody else's business — a broadcast refusal is a punishment announced to
## everybody.
func notice(peer_id: int, text: String) -> void:
	_tell(peer_id, DrEvents.Kind.NOTICE, DrEvents.write_notice(text))


## One routed line to one peer. What [DotGameServices] sends through, via the link.
func send_chat(peer_id: int, wire: Dictionary) -> void:
	_tell(peer_id, DrEvents.Kind.CHAT, DrEvents.write_chat(wire))


## A voice frame, in whichever direction.
##
## [b]Not a [DrEvent].[/b] Voice is fifty packets a second and every event here is reliable,
## so a talk spurt would put a hundred retransmittable messages in front of somebody
## finishing. It also does not go through [DotNetManager]: the message registry seals a
## message set and hashes it, and adding a fifty-hertz opaque blob buys nothing — the packet
## has its own header, sequence and validation in [DotVoicePacket].
func receive_voice(peer_id: int, payload: PackedByteArray) -> DotResult:
	if payload.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "An empty voice frame.")

	if net != null and net.is_server:
		if peer_id <= 0 or player_for_peer(peer_id) == 0:
			# A peer with nobody in the world. Refused rather than relayed: the router
			# stamps the speaker from this id, so relaying one that belongs to nobody puts
			# a voice in the game with no name on it.
			return DotResult.fail(
				DotError.CODE_FORBIDDEN, "That peer has nobody in the world."
			)

		# [b]One path or the other, never both.[/b] [DotGameModule] assigns
		# `voice_relay_fn` to the services layer's `relay_voice`; a game that ALSO connected
		# `voice_requested` to the same router would relay every frame twice — a doubled
		# talk spurt, a doubled rate limit, and a sequence number the jitter buffer sees go
		# backwards.
		if voice_relay_fn.is_valid():
			voice_relay_fn.call(peer_id, payload)
		else:
			voice_requested.emit(peer_id, payload)

		return DotResult.success(null)

	voice_arrived.emit(payload)
	return DotResult.success(null)


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, peer_id)


# --- Server: what a joining peer is told -----------------------------------

func _on_request(message: DotNetMessage) -> void:
	var ask := message as DrRequest

	if ask == null or net == null or not net.is_server:
		return

	# [b]From the message, which dot-net stamped from the TRANSPORT.[/b] A peer id inside a
	# body is a claim; `sender_peer_id` is what the socket said, which is the only version
	# of it a server may act on.
	var peer_id := ask.sender_peer_id

	match ask.kind:
		DrEvents.Ask.READY:
			_admit(peer_id)
		DrEvents.Ask.SAY:
			var said := DrEvents.read_say(ask.reader())

			if bool(said["ok"]):
				# Emitted rather than acted on: everything about what a line means is
				# [DotChatRouter]'s, and the router is the module's.
				say_requested.emit(
					peer_id, StringName(str(said["channel"])), str(said["text"])
				)
		DrEvents.Ask.SPECTATE:
			var step := DrEvents.read_ask_spectate(ask.reader())

			if bool(step["ok"]):
				_spectate_step(peer_id, int(step["direction"]))
		DrEvents.Ask.ROAM:
			_spectate_roam(peer_id)


## Somebody who is out asked to look at somebody else. The server's list, the server's rule.
##
## [b]A refusal goes back as a notice rather than being dropped.[/b] "This server only lets
## you watch your own side" is the answer to a key that did nothing, and a key that silently
## does nothing is reported as broken.
func _spectate_step(peer_id: int, direction: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or game.spectate == null:
		return

	var moved: DotResult = game.spectate.step(player_key(session_id), direction)

	if not moved.ok:
		notice(peer_id, moved.error.message)


## Somebody who is out pressed the free-roam key. The mode is the server's; the refusal
## ("Free roam is off on this server") goes back as a notice, like a refused step.
func _spectate_roam(peer_id: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or game.spectate == null:
		return

	var toggled: DotResult = game.spectate.toggle_roam(player_key(session_id))

	if not toggled.ok:
		notice(peer_id, toggled.error.message)


## Everything in the world, to one peer, once its own copy exists.
##
## [b]On READY and not on connect, and the difference is a whole join's worth of
## messages.[/b] dot-server's signon finishes and THEN the client builds its scene; a server
## that started talking at connect is one whose JOIN and STAGE land on a node
## that does not exist yet and are lost, one "Node not found" per call.
func _admit(peer_id: int) -> void:
	if peer_id <= 0:
		return

	if not _player_of_peer.has(peer_id):
		_ready_unseated[peer_id] = true
		return

	_ready_peers[peer_id] = true

	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	var session_id := int(_player_of_peer[peer_id])

	_tell(peer_id, DrEvents.Kind.HELLO, DrEvents.write_hello(
		session_id,
		game.tick_rate,
		net.clock.tick,
		game.config.countdown_seconds,
		game.round_limit()
	))

	# The stage, before anything that stands on it.
	if not _stage_body.is_empty():
		_tell(peer_id, DrEvents.Kind.STAGE, _stage_body)

	# The course's toys by net id in toy order, which the joiner's own copies are paired with.
	if not _toys_body.is_empty():
		_tell(peer_id, DrEvents.Kind.TOYS, _toys_body)

	for other in _behaviours.keys():
		_tell(peer_id, DrEvents.Kind.JOIN, _join_body(int(other)))

	# Every trap already pressed this round, with the tick it went on: a joiner who was not
	# told would see a trapdoor shut that is open, and their own prediction would sweep them
	# across it.
	if game.stage != null:
		for index in range(game.stage.fired.size()):
			if game.stage.fired[index] < 0:
				continue

			var by: StringName = game.pressed_by.get(index, &"")
			_tell(peer_id, DrEvents.Kind.TRAP, DrEvents.write_trap(
				index, game.stage.fired[index], session_of(by) if by != &"" else 0))

	_tell(peer_id, DrEvents.Kind.PHASE, DrEvents.write_phase(game.phase))
	_tell(peer_id, DrEvents.Kind.CLOCK, _clock_body())


func _join_body(session_id: int) -> PackedByteArray:
	var behaviour: DrPlayerNet = _behaviours.get(session_id)

	if behaviour == null or behaviour.identity == null or behaviour.player == null:
		return PackedByteArray()

	return DrEvents.write_join(
		session_id,
		behaviour.identity.net_id,
		behaviour.player.display_name,
		game.team_of(behaviour.player.player_id),
		behaviour.player.avatar
	)


## Tells everybody who somebody is now: a profile that arrived after they were seated, a
## wardrobe change, an operator's rename. Server only.
##
## [b]Through JOIN, which a client already applies to a player it has.[/b] A second message
## for "this person changed" would be a second thing a joiner has to be told and a second
## order two of them can arrive in; a JOIN is idempotent and already carries all of it.
## An empty [param display_name] keeps the one they have.
func refresh_player(session_id: int, display_name: String, avatar: DotAvatar) -> bool:
	if net == null or not net.is_server or game == null:
		return false

	var player: DrPlayer = game.players.get(player_key(session_id))

	if player == null or not _behaviours.has(session_id):
		return false

	if display_name != "":
		player.display_name = display_name

	player.avatar = avatar
	_broadcast(DrEvents.Kind.JOIN, _join_body(session_id))
	return true


## To every peer that has said it is ready, and to nobody else.
##
## [b]An empty body is dropped rather than sent.[/b] It means an encoder was handed
## something that had already gone — a player whose entity was released before the LEAVE was
## written — and a zero-length event decodes on the far end as a valid message about
## nothing, which is the truncation bug this family has already paid for once.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or body.is_empty():
		return

	for peer_id in _ready_peers.keys():
		_tell(int(peer_id), kind, body)


## One peer, and never zero.
##
## `net.send(msg, 0)` is a BROADCAST in dot-net, so a helper that passed a missing peer id
## straight through would send one player's private message to everybody. game-hungario
## shipped exactly that.
func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if peer_id <= 0 or net == null or body.is_empty():
		return

	net.send(DrEvent.new(kind, body), peer_id)


# --- Client: what it does with all that ------------------------------------

func ask_ready() -> void:
	_ask(DrEvents.Ask.READY, PackedByteArray([0]))


## Says something. The server decides what it means and who hears it.
func ask_say(channel_id: StringName, text: String) -> void:
	if text.strip_edges() == "":
		return

	_ask(DrEvents.Ask.SAY, DrEvents.write_say(channel_id, text))


## Out, and asking for the free camera, or back onto a player from it.
func ask_roam() -> void:
	_ask(DrEvents.Ask.ROAM, DrEvents.write_ask_roam())


## Out, and asking to watch somebody else: +1 next, -1 previous, 0 the other camera.
func ask_spectate(direction: int) -> void:
	_ask(DrEvents.Ask.SPECTATE, DrEvents.write_ask_spectate(direction))


## Sends one encoded voice packet to the server. Client side.
func send_voice(payload: PackedByteArray) -> void:
	if link != null and net != null and not net.is_server:
		link.send_voice(1, payload)


func _ask(kind: int, body: PackedByteArray) -> void:
	if net == null or net.is_server:
		return

	net.send(DrRequest.new(kind, body), 1)


func _on_event(message: DotNetMessage) -> void:
	var event := message as DrEvent

	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		DrEvents.Kind.HELLO:
			_apply_hello(reader)
		DrEvents.Kind.STAGE:
			_apply_stage(reader)
		DrEvents.Kind.TOYS:
			var told := DrEvents.read_toys(reader)
			if bool(told["ok"]):
				_apply_toys(told)
		DrEvents.Kind.JOIN:
			_apply_join(reader)
		DrEvents.Kind.LEAVE:
			var session_id := DrEvents.read_player(reader)
			_release_entity(session_id)
			game.remove_player(player_key(session_id))
			roster_changed.emit(session_id)
		DrEvents.Kind.TEAM:
			var side := DrEvents.read_team(reader)

			if bool(side["ok"]):
				var id := player_key(int(side["player_id"]))
				game.sides[id] = int(side["team"])

				if game.players.has(id):
					(game.players[id] as DrPlayer).team = int(side["team"])

				roster_changed.emit(int(side["player_id"]))
		DrEvents.Kind.CLOCK:
			_apply_clock(reader)
		DrEvents.Kind.ROUND:
			var round_info := DrEvents.read_round(reader)

			if bool(round_info["ok"]):
				game.round_number = int(round_info["round"])

				if bool(round_info["began"]):
					game.phase_elapsed = 0.0
					game.run_elapsed = 0.0

					# Every trap home: the presses were last round's.
					if game.stage != null:
						game.stage.reset_traps()

				round_changed.emit(
					int(round_info["round"]),
					bool(round_info["began"]),
					int(round_info["winner"]),
					str(round_info["why"])
				)
		DrEvents.Kind.PHASE:
			var moved := DrEvents.read_phase(reader)

			if bool(moved["ok"]):
				game.phase = int(moved["phase"])
				game.phase_elapsed = 0.0

				if game.stage != null:
					game.stage.gate_closed = game.phase == game.Phase.COUNTDOWN \
						or game.phase == game.Phase.IDLE

				phase_received.emit(int(moved["phase"]))
		DrEvents.Kind.DEATH:
			var death := DrEvents.read_death(reader)

			if bool(death["ok"]):
				# The fall goes on the player before anybody hears of the death, so the client
				# that draws it reads the server's pick.
				var fell: DrPlayer = game.players.get(player_key(int(death["player_id"]))) \
					if game != null else null
				if fell != null and death.has("death"):
					fell.death = death["death"]
				death_received.emit(
					int(death["player_id"]), int(death["by"]), death["why"]
				)
		DrEvents.Kind.HIT:
			var hit := DrEvents.read_hit(reader)

			if bool(hit["ok"]):
				hit_received.emit(hit["point"], bool(hit["killed"]), bool(hit["headshot"]))
		DrEvents.Kind.ARMED:
			var armed := DrEvents.read_armed(reader)

			if bool(armed["ok"]):
				# Noted on the player here rather than by whoever listens, so every client
				# draws the gun in a watched player's hand: see `DrPlayer.dealt`.
				var dealt_to: DrPlayer = game.players.get(player_key(int(armed["player_id"]))) \
					if game != null else null
				if dealt_to != null:
					dealt_to.note_dealt(armed["weapon_id"], game.round_number)
				armed_received.emit(int(armed["player_id"]), armed["weapon_id"])
		DrEvents.Kind.CHAT:
			var wire := DrEvents.read_chat(reader)

			if bool(wire["ok"]):
				chat_received.emit(wire)
		DrEvents.Kind.NOTICE:
			var text := DrEvents.read_notice(reader)

			if bool(text["ok"]):
				notice_received.emit(str(text["text"]))
		DrEvents.Kind.SPECTATE:
			var view := DrEvents.read_spectate(reader)

			if bool(view["ok"]) and game.spectate != null:
				game.spectate.apply_view(
					player_key(int(view["viewer"])),
					int(view["mode"]),
					player_key(int(view["target"])) if int(view["target"]) != 0 else &"",
					player_key(int(view["killer"])) if int(view["killer"]) != 0 else &"",
					view["death_at"]
				)
				spectate_received.emit(
					int(view["viewer"]), int(view["mode"]), int(view["target"])
				)
		DrEvents.Kind.FINISHED:
			var done := DrEvents.read_finished(reader)

			if bool(done["ok"]):
				finished_received.emit(int(done["player_id"]), int(done["place"]), float(done["seconds"]))
		DrEvents.Kind.TRAP:
			var pressed := DrEvents.read_trap(reader)

			if bool(pressed["ok"]) and game.stage != null \
					and int(pressed["index"]) < game.stage.trap_count():
				var by := int(pressed["by"])
				game.apply_trap_fired(int(pressed["index"]), int(pressed["tick"]),
					player_key(by) if by != 0 else &"")
				trap_received.emit(int(pressed["index"]), int(pressed["tick"]), by)


func _apply_hello(reader: DotNetReader) -> void:
	var hello := DrEvents.read_hello(reader)

	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])

	# [b]The server's tick rate, before anything is derived from it.[/b] Another game in
	# this family shipped with HELLO carrying this and nothing reading it: a browser client
	# counted at the 60 its export declared against a server on 128, so the correction rate
	# was 0.96 and every replicated time was out by 128/60. Produced correctly and consumed
	# by nothing, and invisible to a one-process suite because one process has one engine
	# rate and both ends agree whatever the wire says.
	#
	# Before `sync_from_server`, because the clock converts its error and its lead through
	# `tick_rate` and would otherwise do that arithmetic at the old rate.
	_adopt_tick_rate(int(hello["tick_rate"]))

	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	game.config.countdown_seconds = float(hello["countdown_seconds"])
	game.config.round_seconds = float(hello["round_seconds"])

	_claim_local_player()

	hello_received.emit(local_player_id)


## Puts the whole client — the world, every controller and the ENGINE — on the server's rate.
##
## That last one is not cosmetic. Measured in another game in this family at 60 against 128:
## the simulation stayed correct, because the clock is asked how many ticks a frame is worth
## — it just ran them in bursts of two and three, and the camera advanced 74 mm on six frames
## out of seven and 112 mm on the seventh. A 47% change in apparent speed, eight times a
## second.
##
## A server never calls this: its rate is `sv_tickrate`, and adopting a peer's would be a
## client telling the server how fast to run.
func _adopt_tick_rate(rate: int) -> void:
	if net == null or net.is_server or game == null or rate <= 0 or rate == game.tick_rate:
		return

	var before := game.tick_rate

	if not game.set_tick_rate(rate):
		return

	net.config.tick_rate = game.tick_rate
	# The LIVE one, which is built from the config back at `setup()` and is therefore not
	# updated by writing the config alone.
	net.clock.tick_rate = game.tick_rate
	# dot-net API 7 has DotNetClock.adopt_tick_rate(), which also raises the engine's step cap to
	# a quarter second of ticks, so a slow-frame client keeps up with the server. A shell built
	# before it gets the same rule here; remove this branch when the oldest shell is API 7.
	if DotAddonApi.build_level("dot_net") >= 7:
		DotNetClock.adopt_tick_rate(game.tick_rate)
	else:
		Engine.max_physics_steps_per_frame = maxi(Engine.max_physics_steps_per_frame, ceili(0.25 * float(game.tick_rate)))
		Engine.physics_ticks_per_second = game.tick_rate

	DotLog.info(CHANNEL, "adopted the server's tick rate", {
		"was": before, "now": game.tick_rate, "engine": Engine.physics_ticks_per_second,
	})


## The course, which on a client is a document it builds exactly as the server did.
##
## [b]Refused with a line, never half built.[/b] A client a format behind the server decodes
## a document it cannot read; [DrCourseDoc] says so, and the honest answer is no course and a
## WARN rather than a course with holes in it.
func _apply_stage(reader: DotNetReader) -> void:
	var told := DrEvents.read_stage(reader)

	if not bool(told["ok"]) or game == null:
		return

	var decoded := DrCourseDoc.decode(told["encoded"])

	if not decoded.ok:
		DotLog.warn(CHANNEL, "the server sent a stage this build cannot build", {
			"why": decoded.error.message, "detail": decoded.error.detail,
		})
		return

	var built := game.build_stage(decoded.value)

	if built.ok:
		stage_received.emit(game.stage.id())


func _apply_join(reader: DotNetReader) -> void:
	var join := DrEvents.read_join(reader)

	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var id := player_key(session_id)
	var player: DrPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]), int(join["team"]))

		if player == null:
			return

		# A client never samples: the client loop hands it commands, and the local player is
		# the only one whose commands exist at all.
		player.sampler = null
		player.samples_input = false

		# [b]This client's own player is owned by this client, and nobody else's is.[/b]
		# Until 2026-09-25 every mirror was built with owner 0, this client's own included,
		# so `is_owner` was false for the local player, `registry.predicted()` was empty and
		# `client_tick` simulated nobody: the player moved only when a snapshot came back, a
		# round trip behind the keys, and the camera — drawn from `render_state`, a blend
		# against a previous tick the controller never recorded — lurched between where the
		# player was last teleported and where the server had them. Every check passed
		# anyway, because a client adopting the server's answer also agrees with the server.
		#
		# By session and not by a peer id on the wire: JOIN does not carry one, and what
		# `is_owner` compares is the owner against THIS registry's local peer — so the local
		# peer id is the only right value whatever the server calls the connection, and the
		# wire (and therefore a published pack's server half) is unchanged. HELLO, which sets
		# `local_player_id`, is sent before every JOIN in `_admit` on the same reliable
		# channel; [method _apply_hello] still claims a player that got here first, because
		# an order is a property of the server, not of this file.
		var identity := _build_entity(player, _mirror_owner(session_id))
		var registered := net.registry.register(
			identity, int(join["net_id"]), net.clock.tick, net.config
		)

		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			return
	else:
		player.display_name = str(join["name"])

	# Both branches: a JOIN for somebody this client already has is the server saying who
	# they are NOW — see [method refresh_player].
	player.avatar = join["avatar"]
	game.sides[id] = int(join["team"])
	player.team = int(join["team"])
	roster_changed.emit(session_id)


## Who owns a mirrored player on this client: this client, if it is this client's own
## player, and the server's 0 otherwise.
##
## [b]Never the local peer for anybody else[/b], or this client would predict a person whose
## keys it never had. And a client whose local peer is 0 claims nothing: 0 is the server's
## owner id, and on such a registry dot-net's `is_owner` (owner == local peer) is already true
## of every owner-0 mirror — which this function cannot undo, and which no client here runs
## into, because `DrClient` takes its id from the multiplayer API and that never answers 0.
func _mirror_owner(session_id: int) -> int:
	if net == null or net.local_peer_id <= 0:
		return 0

	if local_player_id != 0 and session_id == local_player_id:
		return net.local_peer_id

	return 0


## The local player's mirror, claimed if it arrived before HELLO said whose it was.
##
## Not the order `_admit` sends in, and that is why it is belt and braces rather than a path
## this game takes: a JOIN that reached this peer before its HELLO would otherwise leave the
## local player unpredicted for the rest of the session, with every check still passing —
## which is the bug [method _apply_join] documents.
func _claim_local_player() -> void:
	var mine: DrPlayerNet = _behaviours.get(local_player_id)

	if mine == null or mine.identity == null or not mine.identity.is_registered():
		return

	var claimed := _mirror_owner(local_player_id)

	if claimed == 0 or mine.identity.owner_peer_id == claimed:
		return

	DotLog.debug(CHANNEL, "claimed the local player after HELLO", {
		"session": local_player_id, "net_id": mine.identity.net_id,
	})
	var _changed := net.registry.change_owner(mine.identity.net_id, claimed)


func _apply_clock(reader: DotNetReader) -> void:
	var clock := DrEvents.read_clock(reader)

	if not bool(clock["ok"]):
		return

	game.round_number = int(clock["round"])
	game.phase_elapsed = float(clock["elapsed"])
	game.run_elapsed = float(clock["run_elapsed"])
	game.phase = int(clock["phase"])
	game.remote_runners = int(clock["runners"])
	game.remote_activators = int(clock["activators"])
	game.remote_playable = bool(clock["playable"])


# --- Reporting -------------------------------------------------------------

func describe() -> Dictionary:
	var out := {
		"server": net != null and net.is_server,
		"players": _behaviours.size(),
		"ready_peers": _ready_peers.size(),
		"tick": _tick,
	}

	if not (net != null and net.is_server):
		out["local_player"] = local_player_id

	if link != null:
		out["link"] = link.describe()

	return out


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray([
		"bridge     %s" % ("server" if net != null and net.is_server else "client"),
		"players    %d" % _behaviours.size(),
		"peers      %d ready" % _ready_peers.size(),
		"tick       %d" % _tick,
	])

	if link != null:
		lines.append_array(link.describe_lines())

	return lines
