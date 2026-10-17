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
## [b]The beacon's ping is not here, deliberately[/b], as in mg-smash-copter: [DotFxBeacon]
## synthesises its own tone, and the day real audio ships `beacon` is the id it moves to.

const CHANNEL := "dr.audio"

## Where the real files go when somebody produces them. Rebased, because a delivered pack
## mounts this game somewhere other than `res://`.
static var SOUND_DIR := DrPaths.rebase("res://audio")

## A trap going off. Positional: you hear it where it is. [constant TRAP] is the generic
## impact; the others are the machinery, chosen per trap by [method trap_sound].
const TRAP := &"trap"
## A blade spinning up: a whine.
const TRAP_SAW := &"trap_saw"
## A floor leaving: a trapdoor's bang, a bridge rolling over, steps dropping away.
const TRAP_DROP := &"trap_drop"
## Something heavy arriving: a press, jaws, a spike floor.
const TRAP_CRUSH := &"trap_crush"
## A burner lighting.
const TRAP_FIRE := &"trap_fire"
## Walls closing: metal dragged along metal.
const TRAP_GRIND := &"trap_grind"
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

## Everybody's footsteps by what they stand on, and the course's bed: dot-audio's stock
## (Kenney's footsteps, generated beds, all CC0; the addon's stock/CREDITS.md).
var steps: DotAudioFootsteps = null
var ambience: DotAudioAmbience = null

## Each course's bed and the ground it is built of, for a course document that names neither
## (`"ambience"` and `"surface"` in a document win). Courses are machinery: the deck is steel
## plate or stone, and a works hums.
const COURSE_SOUND := {
	&"dr_foundry": [&"amb_industrial", &"metal"],
	&"dr_ice_works": [&"amb_wind", &"metal"],
	&"dr_temple": [&"amb_cave", &"concrete"],
	&"dr_quarry": [&"amb_wind", &"concrete"],
	&"dr_practice": [&"amb_industrial", &"concrete"],
}


static func ids() -> Array[StringName]:
	var out: Array[StringName] = [
		TRAP, TRAP_SAW, TRAP_DROP, TRAP_CRUSH, TRAP_FIRE, TRAP_GRIND, FINISH, COUNTDOWN, GATE, PLAYER_DOWN, YOU_ARE_OUT, ROUND_START, ROUND_END,
		SHOWDOWN, WEAPON_SHOT, WEAPON_SWING, WEAPON_LAUNCH, WEAPON_BEAM, WEAPON_THROW,
		UI_CLICK, UI_DENY,
		# dot-player-char's dead bodies.
		DotPlayerDeathReactions.SOUND_THUD, DotPlayerDeathReactions.SOUND_FACE_PLANT,
		DotPlayerDeathReactions.SOUND_SLUMP, DotPlayerDeathReactions.SOUND_WHOOSH,
	]
	# dot-props' toys.
	for row: Dictionary in DotPropToySounds.rows():
		out.append(StringName(row["id"]))
	# A typed array plus a typed array is an untyped one: appended, not added.
	out.append_array(DotAudioStock.ids())
	return out


## Every decision about every noise. The distances are a course's: a trap further back than
## sixty metres is not about you.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	c.add(_placed(TRAP, 60.0, 12.0, 4, 85, 0.9, 1.1))

	for machine: StringName in [TRAP_SAW, TRAP_DROP, TRAP_CRUSH, TRAP_FIRE, TRAP_GRIND]:
		c.add(_placed(machine, 60.0, 12.0, 4, 85, 0.94, 1.06))
	c.add(_placed(PLAYER_DOWN, 80.0, 12.0, 3, 65, 0.95, 1.05))

	# Footsteps and ambience beds, the family's stock. Added first so nothing here is shadowed.
	DotAudioStock.add_to(c)

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

	# A body landing: dot-player-char's stock death sounds (Kenney, CC0), shipped in the addon.
	for row: Dictionary in DotPlayerDeathSounds.rows():
		var fall := _placed(row["id"], 45.0, 8.0, 3, 50, float(row["pitch_min"]), float(row["pitch_max"]))
		fall.path = row["path"]
		fall.variants = row["variants"]
		fall.gain_db = float(row["gain_db"])
		fall.cooldown_ms = int(row["cooldown_ms"])
		c.add(fall)

	# The course's toys: dot-props' stock toy sounds (Kenney, CC0), shipped in the addon.
	for row: Dictionary in DotPropToySounds.rows():
		var toy := _placed(row["id"], float(row["distance"]), 6.0, 3, 30, float(row["pitch_min"]), float(row["pitch_max"]))
		toy.path = row["path"]
		toy.variants = row["variants"]
		toy.gain_db = float(row["gain_db"])
		toy.cooldown_ms = int(row["cooldown_ms"])
		c.add(toy)

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
		# Stand-ins only for a build without dot-props' toy files.
		DotPropToySounds.BOUNCE: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.THUMP: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.KNOCK: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.PIN: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.WOOD: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.RUBBER: DotAudioSynth.Voice.IMPACT,
		DotPropToySounds.PUNCH: DotAudioSynth.Voice.HURT,
		DotPropToySounds.METAL: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.BELL: DotAudioSynth.Voice.PICKUP,
		DotPropToySounds.CLICK: DotAudioSynth.Voice.CLICK,
		DotPropToySounds.WATER: DotAudioSynth.Voice.STEP,
		DotPropToySounds.BOING: DotAudioSynth.Voice.SPAWN,
		DotPropToySounds.HORN: DotAudioSynth.Voice.BLIP,
		# Stand-ins only for a build without dot-player-char's files.
		DotPlayerDeathReactions.SOUND_THUD: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_FACE_PLANT: DotAudioSynth.Voice.IMPACT,
		DotPlayerDeathReactions.SOUND_SLUMP: DotAudioSynth.Voice.STEP,
		DotPlayerDeathReactions.SOUND_WHOOSH: DotAudioSynth.Voice.SPAWN,
	}


## Which machinery a trap sounds like: what its document says, or what its parts do.
##
## [b]Read from the parts because a trap is parts, not a kind[/b] (see DrCourseDoc._trap): a
## part that spins is a saw, fire is fire, a part that turns or a floor that moves away is
## a floor leaving, spikes that travel are something arriving, and anything else is the
## impact every trap made before there were machines. Walls that close sideways grind.
static func trap_sound(spec: Dictionary) -> StringName:
	match str(spec.get("sound", "")):
		"saw":
			return TRAP_SAW
		"drop":
			return TRAP_DROP
		"crush":
			return TRAP_CRUSH
		"fire":
			return TRAP_FIRE
		"grind":
			return TRAP_GRIND
		"impact":
			return TRAP

	var parts: Array = spec.get("parts", [])
	var falls := false
	var arrives := false
	var sideways := false

	for part: Variant in parts:
		if not (part is Dictionary):
			continue

		var d := part as Dictionary

		if absf(float(d.get("spin", 0.0))) > 0.0:
			return TRAP_SAW

		if str(d.get("look", "")) == "fire":
			return TRAP_FIRE

		var move: Variant = d.get("move", Vector3.ZERO)
		var by: Vector3 = move if move is Vector3 else Vector3.ZERO

		if d.has("turn") or (not bool(d.get("lethal", false)) and by.y < -0.5):
			falls = true
		elif bool(d.get("lethal", false)) and by.length() > 0.1:
			if absf(by.y) < 0.1:
				sideways = true
			else:
				arrives = true

	if falls:
		return TRAP_DROP

	if sideways:
		return TRAP_GRIND

	if arrives:
		return TRAP_CRUSH

	return TRAP


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
	# Measured toward the family's -17 LUFS (dot-audio docs/loudness.md): a 40 s stand-in run
	# on the practice course read -19.7 LUFS integrated with the beds and steps in; -18.0 after.
	# Once the stand-in turned off walls (2026-10-12): a run is as loud as the runner is alive,
	# so it swings with how soon a trap gets it (-21.7 at +3.5 with the camera at 45 m, -18.5
	# at 145 m). At +6.5: -17.1, -17.1 and -18.9 (camera 165, 166 and 95 m).
	manager.loudness_trim_db = 6.5
	add_child(manager)

	var ready_now := manager.setup()

	if not ready_now.ok:
		return ready_now.wrap("deathrun audio")

	steps = DotAudioFootsteps.new()
	steps.name = "Footsteps"
	steps.manager = manager
	add_child(steps)
	ambience = DotAudioAmbience.new()
	ambience.name = "Ambience"
	ambience.manager = manager
	ambience.fallback_bed = &"amb_industrial"
	add_child(ambience)

	# Only on a real sink: the manager has already decided whether there is a device, and a
	# headless process has nothing to bake for.
	var godot_sink := manager.sink as DotAudioSinkGodot

	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(manager.catalogue, sound_recipes())
		_bake_machinery(godot_sink.bank, manager.catalogue)
		# INFO, once: the answer to "why does it sound like that" is in this line.
		DotLog.info(CHANNEL, "no audio files; synthesised stand-ins are in use", {
			"ids": sound_recipes().size(), "dir": SOUND_DIR,
		})

	return DotResult.success(null)


## Where the ears are, once a frame. The camera, which is the spectator's camera too.
func listen_from(at: Vector3) -> void:
	if manager != null:
		manager.listener_position = at


## A course arrived: its bed and its ground.
func on_course(id: StringName, doc: Dictionary) -> void:
	var row: Array = COURSE_SOUND.get(id, [&"amb_industrial", &"concrete"])
	if steps != null:
		steps.default_surface = StringName(str(doc.get("surface", row[1])))
	if ambience != null:
		ambience.set_map_bed(StringName(str(doc.get("ambience", row[0]))))


## Everybody on the course steps, once a frame: the players this client knows, bots included.
func keep_walkers(bodies: Array) -> void:
	if steps != null:
		steps.keep(bodies)


## [param spec] is the trap's document; without one it is the generic impact.
func on_trap(at: Vector3, spec: Dictionary = {}) -> bool:
	return _at(trap_sound(spec) if not spec.is_empty() else TRAP, at)


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


## A dead body's sound (dot-player-char's ragdolls), where it landed.
## A toy's sound (dot-props' toys): a bounce, a knock, where it happened.
func on_toy(id: StringName, at: Vector3, strength: float) -> bool:
	return _at(id, at, clampf(strength, 0.25, 1.0))


func on_body(id: StringName, at: Vector3, volume: float) -> bool:
	return _at(id, at, clampf(volume, 0.3, 1.0))


func _at(id: StringName, at: Vector3, volume: float = 1.0) -> bool:
	return manager != null and manager.play_at(id, at, volume) != 0


func _flat_play(id: StringName) -> bool:
	return manager != null and manager.play(id) != 0


# --- The machinery, synthesised ---------------------------------------------------
#
# dot-audio's voices are one swept tone with noise, which is a click, a shot or a blip; a saw
# winding up or a press landing is several things at once, so these are baked here, into the
# same bank, under the id and the path a real file would have. A real `.ogg` still wins.

const RATE := 22050


static func _bake_machinery(bank: Dictionary, catalogue: DotAudioCatalogue) -> void:
	var made := {
		TRAP_SAW: _saw(), TRAP_DROP: _drop(), TRAP_CRUSH: _crush(),
		TRAP_FIRE: _fire(), TRAP_GRIND: _grind(),
	}

	for id: StringName in made:
		bank[id] = made[id]
		var def := catalogue.find(id)

		if def != null and not def.path.is_empty():
			bank[def.path] = made[id]


static func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)

	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.data = data
	return wav


static func _buffer(seconds: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(int(RATE * seconds))
	return out


## A blade winding up and running: a sawtooth climbing from 600 to 1500 Hz, with grit.
static func _saw() -> AudioStreamWAV:
	var out := _buffer(1.3)
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var phase := 0.0

	for i in out.size():
		var t := float(i) / RATE
		phase = fmod(phase + lerpf(600.0, 1500.0, minf(t / 0.5, 1.0)) / RATE, 1.0)
		var env := minf(t / 0.05, 1.0) * clampf((1.3 - t) / 0.4, 0.0, 1.0)
		out[i] = ((phase * 2.0 - 1.0) * 0.30 + rng.randf_range(-1.0, 1.0) * 0.08) * env

	return _wav(out)


## A trapdoor going: the latch's crack, then the leaves hitting their stops, low and wooden.
static func _drop() -> AudioStreamWAV:
	var out := _buffer(0.7)
	var rng := RandomNumberGenerator.new()
	rng.seed = 22

	for i in out.size():
		var t := float(i) / RATE
		var crack := rng.randf_range(-1.0, 1.0) * exp(-t * 60.0) * 0.6
		var thud := 0.0

		if t > 0.12:
			var u := t - 0.12
			thud = sin(TAU * lerpf(110.0, 60.0, minf(u / 0.3, 1.0)) * u) * exp(-u * 9.0) * 0.8
			thud += rng.randf_range(-1.0, 1.0) * exp(-u * 30.0) * 0.25

		out[i] = crack + thud

	return _wav(out)


## Something heavy landing: a very low thump with a noise body.
static func _crush() -> AudioStreamWAV:
	var out := _buffer(0.8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var low := 0.0

	for i in out.size():
		var t := float(i) / RATE
		low = lerpf(low, rng.randf_range(-1.0, 1.0), 0.08)
		out[i] = (sin(TAU * lerpf(70.0, 38.0, minf(t / 0.4, 1.0)) * t) * 0.85 + low * 1.4) * exp(-t * 6.0)

	return _wav(out)


## A burner lighting: a whoomp, then a roar that falls away.
static func _fire() -> AudioStreamWAV:
	var out := _buffer(1.5)
	var rng := RandomNumberGenerator.new()
	rng.seed = 24
	var low := 0.0

	for i in out.size():
		var t := float(i) / RATE
		low = lerpf(low, rng.randf_range(-1.0, 1.0), 0.12)
		var whoomp := sin(TAU * 55.0 * t) * exp(-t * 10.0) * 0.5
		var flicker := 0.8 + 0.2 * sin(TAU * 7.0 * t)
		out[i] = whoomp + low * 1.5 * flicker * minf(t / 0.06, 1.0) * clampf((1.5 - t) / 0.7, 0.0, 1.0)

	return _wav(out)


## Walls dragged closed: mid noise chattering at 28 Hz, the way metal skips along metal.
static func _grind() -> AudioStreamWAV:
	var out := _buffer(1.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 25
	var mid := 0.0

	for i in out.size():
		var t := float(i) / RATE
		mid = lerpf(mid, rng.randf_range(-1.0, 1.0), 0.35)
		var chatter := 0.55 + 0.45 * sin(TAU * 28.0 * t)
		out[i] = mid * 0.7 * chatter * minf(t / 0.04, 1.0) * clampf((1.0 - t) / 0.3, 0.0, 1.0)

	return _wav(out)


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}
