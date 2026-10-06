extends Node

const DrPaths := preload("dr_paths.gd")

## What this game makes a noise about, and the noise, on the client.
##
## [b]On a course the sounds are the warning.[/b] A trap going off is heard where it is, so
## a runner two traps back hears the one ahead go and knows it is spent; a death has its own
## noise, so a runner who did not see it still knows the person in front is gone. At the end,
## a shot behind you is the warning that works without looking.
##
## [b]A catalogue of ids and a table of stand-ins, which is the family's shape.[/b] dot-audio
## decides what is audible, how many at once, how far away it stops mattering and what loses
## to what; [method sound_catalogue] is those decisions, as a document naming paths nobody
## has produced yet. [method sound_recipes] says which synthesised voice stands in for each
## id until they are — and [DotAudioSinkGodot] consults the file before the stand-in, so
## dropping a real `.ogg` into `audio/` switches that one id over with no code change.
##
## [b]Never on a server, and never deciding anything.[/b] Every hook here is called by
## [DrClient] from something the world or the wire already said.
##
## [b]The beacon's ping is not here, deliberately[/b], as in mg-smash-copter: [DrBeacon]
## synthesises its own tone, and the day real audio ships `beacon` is the id it moves to.

const CHANNEL := "dr.audio"

## Where the real files go when somebody produces them. Rebased, because a delivered pack
## mounts this game somewhere other than `res://`.
static var SOUND_DIR := DrPaths.rebase("res://audio")

## A trap going off. Positional: you hear it where it is.
const TRAP := &"trap"
## A runner across the finish; flat and louder when it is you.
const FINISH := &"finish"
## The countdown's last seconds, and the gate dropping.
const COUNTDOWN := &"countdown"
const GATE := &"gate"
## Somebody else out.
const PLAYER_DOWN := &"player_down"
## You, out. Flat.
const YOU_ARE_OUT := &"you_are_out"
const ROUND_START := &"round_start"
const ROUND_END := &"round_end"
## The activators called to the end.
const SHOWDOWN := &"showdown"
const WEAPON_SHOT := &"weapon_shot"
const WEAPON_SWING := &"weapon_swing"
const WEAPON_LAUNCH := &"weapon_launch"
const WEAPON_BEAM := &"weapon_beam"
const WEAPON_THROW := &"weapon_throw"
const UI_CLICK := &"ui_click"
const UI_DENY := &"ui_deny"

var manager: DotAudioManager = null


static func ids() -> Array[StringName]:
	return [
		TRAP, FINISH, COUNTDOWN, GATE, PLAYER_DOWN, YOU_ARE_OUT, ROUND_START, ROUND_END,
		SHOWDOWN, WEAPON_SHOT, WEAPON_SWING, WEAPON_LAUNCH, WEAPON_BEAM, WEAPON_THROW,
		UI_CLICK, UI_DENY,
	]


## Every decision about every noise. The distances are a course's: a trap further back than
## sixty metres is not about you.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	c.add(_placed(TRAP, 60.0, 12.0, 4, 85, 0.9, 1.1))
	c.add(_placed(PLAYER_DOWN, 80.0, 12.0, 3, 65, 0.95, 1.05))

	c.add(_flat(FINISH, &"UI", 2, 80))
	var beep := _flat(COUNTDOWN, &"UI", 1, 70)
	beep.cooldown_ms = 400
	c.add(beep)
	c.add(_flat(GATE, &"UI", 1, 85))
	c.add(_flat(YOU_ARE_OUT, &"SFX", 1, 100))
	c.add(_flat(ROUND_START, &"UI", 1, 80))
	c.add(_flat(ROUND_END, &"UI", 1, 80))
	c.add(_flat(SHOWDOWN, &"UI", 1, 85))

	var shot := _placed(WEAPON_SHOT, 110.0, 14.0, 3, 80, 0.94, 1.06)
	shot.tags = [&"weapon"]
	c.add(shot)
	var swing := _placed(WEAPON_SWING, 30.0, 6.0, 2, 55, 0.9, 1.1)
	swing.tags = [&"weapon"]
	c.add(swing)
	var launch := _placed(WEAPON_LAUNCH, 140.0, 16.0, 2, 82, 0.95, 1.05)
	launch.tags = [&"weapon"]
	c.add(launch)
	var beam := _placed(WEAPON_BEAM, 90.0, 12.0, 1, 75, 1.0, 1.0)
	beam.cooldown_ms = 180
	beam.tags = [&"weapon"]
	c.add(beam)
	var throw := _placed(WEAPON_THROW, 40.0, 8.0, 2, 55, 0.95, 1.05)
	throw.tags = [&"weapon"]
	c.add(throw)

	var click := _flat(UI_CLICK, &"UI", 2, 60)
	click.cooldown_ms = 60
	c.add(click)
	var deny := _flat(UI_DENY, &"UI", 1, 60)
	deny.cooldown_ms = 250
	c.add(deny)

	return c


## Which synthesised voice stands in for each id until a file exists.
static func sound_recipes() -> Dictionary:
	return {
		TRAP: DotAudioSynth.Voice.IMPACT,
		FINISH: DotAudioSynth.Voice.SPAWN,
		COUNTDOWN: DotAudioSynth.Voice.BLIP,
		GATE: DotAudioSynth.Voice.SHOT_HEAVY,
		PLAYER_DOWN: DotAudioSynth.Voice.HURT,
		YOU_ARE_OUT: DotAudioSynth.Voice.DIE,
		ROUND_START: DotAudioSynth.Voice.SPAWN,
		ROUND_END: DotAudioSynth.Voice.PICKUP,
		SHOWDOWN: DotAudioSynth.Voice.SHOT_HEAVY,
		WEAPON_SHOT: DotAudioSynth.Voice.SHOT,
		WEAPON_SWING: DotAudioSynth.Voice.STEP,
		WEAPON_LAUNCH: DotAudioSynth.Voice.SHOT_HEAVY,
		WEAPON_BEAM: DotAudioSynth.Voice.SHOT_TIGHT,
		WEAPON_THROW: DotAudioSynth.Voice.CLICK,
		UI_CLICK: DotAudioSynth.Voice.CLICK,
		UI_DENY: DotAudioSynth.Voice.DENY,
	}


static func weapon_sound(kind: int) -> StringName:
	match kind:
		ZeeWeaponNet.KIND_SHOT:
			return WEAPON_SHOT
		ZeeWeaponNet.KIND_SWING:
			return WEAPON_SWING
		ZeeWeaponNet.KIND_SPAWN:
			return WEAPON_LAUNCH
		ZeeWeaponNet.KIND_BEAM:
			return WEAPON_BEAM
		ZeeWeaponNet.KIND_THROW:
			return WEAPON_THROW
		_:
			return &""


static func _placed(
	id: StringName,
	max_distance: float,
	unit_size: float,
	concurrent: int,
	priority: int,
	pitch_min: float,
	pitch_max: float
) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.kind = DotAudioDef.Kind.POSITIONAL_3D
	def.bus = &"SFX"
	def.max_distance = max_distance
	def.unit_size = unit_size
	def.max_concurrent = concurrent
	def.priority = priority
	def.pitch_min = pitch_min
	def.pitch_max = pitch_max
	return def


static func _flat(id: StringName, bus: StringName, concurrent: int, priority: int) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.bus = bus
	def.max_concurrent = concurrent
	def.priority = priority
	return def


# --- Building ---------------------------------------------------------------

func setup() -> DotResult:
	manager = DotAudioManager.new()
	manager.name = "Audio"
	manager.catalogue = sound_catalogue()
	manager.mixer = DotAudioMixer.new()
	# Not published: a client and a server in one process, which every suite here is, would
	# otherwise fight over one registry name — and nothing looks this up by name anyway.
	manager.register_as_service = false
	# Two traps, a death and a firefight at once is the busiest this game gets.
	manager.voices = 24
	add_child(manager)

	var ready_now := manager.setup()

	if not ready_now.ok:
		return ready_now.wrap("deathrun audio")

	# Only on a real sink: the manager has already decided whether there is a device, and a
	# headless process has nothing to bake for.
	var godot_sink := manager.sink as DotAudioSinkGodot

	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(manager.catalogue, sound_recipes())
		# INFO, once: the answer to "why does it sound like that" is in this line.
		DotLog.info(CHANNEL, "no audio files; synthesised stand-ins are in use", {
			"ids": sound_recipes().size(), "dir": SOUND_DIR,
		})

	return DotResult.success(null)


## Where the ears are, once a frame. The camera, which is the spectator's camera too.
func listen_from(at: Vector3) -> void:
	if manager != null:
		manager.listener_position = at


func on_trap(at: Vector3) -> bool:
	return _at(TRAP, at)


func on_finish(mine: bool) -> bool:
	return _flat_play(FINISH) if mine else false


func on_countdown() -> bool:
	return _flat_play(COUNTDOWN)


func on_gate() -> bool:
	return _flat_play(GATE)


func on_death(at: Vector3, mine: bool) -> bool:
	if mine:
		return _flat_play(YOU_ARE_OUT)

	return _at(PLAYER_DOWN, at)


func on_round(began: bool) -> bool:
	return _flat_play(ROUND_START if began else ROUND_END)


func on_showdown() -> bool:
	return _flat_play(SHOWDOWN)


func on_weapon(at: Vector3, kind: int) -> bool:
	var id := weapon_sound(kind)
	return _at(id, at) if id != &"" else false


func click() -> bool:
	return _flat_play(UI_CLICK)


func deny() -> bool:
	return _flat_play(UI_DENY)


func _at(id: StringName, at: Vector3, volume: float = 1.0) -> bool:
	return manager != null and manager.play_at(id, at, volume) != 0


func _flat_play(id: StringName) -> bool:
	return manager != null and manager.play(id) != 0


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}
