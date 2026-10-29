extends Node

## The bridge's constants, signals and state, split out of `dr_net_bridge.gd` to keep it under the size budget. No `class_name`; the bridge extends this.

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

const CHANNEL := "dr.net"

## Bytes of acknowledgement in front of every input packet. [method DotNetManager.encode_ack].
const ACK_BYTES := 4

## Commands in every input packet: this tick's and the four before it, so a lost packet costs no tick
## unless the next four are lost too. Over ENet one copy meant the server ran on the previous command.
const INPUT_COPIES := 5

## How often the round clock and its numbers go out, in ticks: twice a second, because they only
## change when somebody finishes or a second passes. The client advances the clock between messages
## (see [method _apply_clock]).
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
signal death_received(player_id: int, by: int, why: StringName, weapon_id: StringName)

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

## Somebody pressed Enter. Server side; the bridge carries chat and decides nothing, who may say
## what is [DotChatRouter]'s.
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

## Where the clock learns the link's length in milliseconds; dot-net cannot measure a transport,
## dot-server's heartbeat can ([method DotClientLink.ping_ms]). With no sample every command is
## stamped for a tick already simulated and discarded as late.
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

## The next session id for somebody the world made itself, well above anything dot-server issues.
## A bot needs one because a player called `bot` parses back to session ZERO, dot-net's broadcast address.
const FIRST_BOT_SESSION := 900000

var _next_bot_session: int = FIRST_BOT_SESSION

var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
## Carries the game's profile runtime over this manager (rows down, for a remote admin's panel).
var profile_link: DotNetProfileLink = null
## Server: peers whose READY came before their seat ([method add_player]); over lossy ENet READY can
## overtake `loaded`. Admitted when seated.
var _ready_unseated: Dictionary = {}

var _tick: int = 0
var _game_ticked_for: int = -1

## Server only: whether [method DotNetManager.server_tick] is on the stack, and the net ids let go of
## meanwhile. An entity freed mid-tick would get a fresh lag-compensation track recorded for it
## that nothing forgets; they are forgotten again once the manager lets go of its list.
var _in_server_tick := false
var _unregistered_in_tick: Array[int] = []
var _client_ticked_for: int = -1

## The stage the clients were last sent, so a late joiner is sent the same bytes.
var _stage_body: PackedByteArray = PackedByteArray()
