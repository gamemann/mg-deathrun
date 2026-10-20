extends RefCounted

## What a course IS: a JSON document, checked here before anything is built.
##
## [b]A course is a document, not a scene, and that is the decision every other file in this
## game leans on.[/b] mg-wipeout's reasoning, taken unchanged: a scene per course would be
## content to import, to rebase inside a mounted pack and to keep in step across a server and
## every client; a document is a few kilobytes the server reads off disk and SENDS to each
## client at the top of a round. A client needs no course files, a server is given a new course
## by dropping a file in a directory, and the two ends cannot disagree about where a trapdoor
## is, because there is one copy and it travelled.
##
## [b]One document is the whole map:[/b] the runners' corridor, the activators' corridor beside
## it, the traps and their buttons, the finish, and the end arena the round is settled in.
## A course with the arena in another file would be two documents that have to agree about
## where one stops and the other starts.
##
## [b]Validated, and a refused document is a line in the log, not a broken round.[/b] The
## catalogue loads everything it can and skips what this refuses, saying why.
##
## Every length is metres, every angle degrees, every time seconds. A position is the CENTRE
## of what it places unless the field's own comment says otherwise. `courses/README.md` is
## the mapper's copy of this, with an example of every kind.

const CHANNEL := "dr.doc"

## The format this build reads. A document written for a later one is refused rather than
## half-built, because a part this build has never heard of is a hole in a trap.
const FORMAT := 1

const KIND_COURSE := "course"

## The largest a document may be on the wire, compressed, in bytes. See mg-wipeout: a reliable
## event is retransmitted until it arrives, and sixty-four kilobytes is far past a course.
const WIRE_LIMIT := 65536

## The most still pieces one document may hold. 2400 compresses to well under WIRE_LIMIT (a 3500-piece converted map is about 52 KB); a converted map is brushes, hundreds of boxes.
const MAX_PIECES := 2400

## The most traps, and the most parts one trap may move.
const MAX_TRAPS := 48
const MAX_TOYS := 64
const MAX_PARTS := 32

## The machinery a trap can sound like, for a mapper who wants to say so (`"sound"`).
const TRAP_SOUNDS: Array[String] = ["", "saw", "drop", "crush", "fire", "grind", "impact"]

## Every piece kind, and the fields each one must have. The meaning of each is in [DrCourse].
const PIECES := {
	# Still things.
	"box": ["at", "size"],
	"ramp": ["at", "size", "pitch"],
	"ball": ["at", "radius"],
	"cylinder": ["at", "radius", "height"],
	# Things that move whether or not anybody presses anything, and carry whoever stands on
	# them: the moving platforms a course has between its traps.
	"mover": ["from", "to", "size", "period"],
	"turntable": ["at", "radius", "speed"],
	# A volume that kills whoever is in it, always: a spike pit, a pool, a drop.
	"kill": ["at", "size"],
	# A pad that moves whoever steps on it to `to` (their feet), facing `heading` degrees: where
	# a map hands people on to its next stretch. Solid and still; it is a place, not a machine.
	"teleport": ["at", "size", "to"],
}

## The roles a surface can be drawn as. See [DrTextures.Role].
const ROLES := ["deck", "pillar", "cannon", "arena", "hazard", "safe"]

## How a trap part is drawn. The shape it collides and kills with is always its box.
const LOOKS := ["block", "spikes", "blade", "fire", "liquid", "wind"]

## Which way a part drawn as spikes points, in the part's own frame.
const FACES := ["up", "down", "forward", "back", "left", "right"]


## Reads a document from JSON text, and checks it.
static func parse_json(text: String, origin: String = "") -> DotResult:
	var json := JSON.new()
	var parsed := json.parse(text)

	if parsed != OK:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The document is not JSON.",
			"%s line %d: %s" % [origin, json.get_error_line(), json.get_error_message()]
		)

	if typeof(json.data) != TYPE_DICTIONARY:
		return DotResult.fail(DotError.CODE_PARSE, "The document is not a JSON object.", origin)

	return validate(json.data as Dictionary)


## Checks a document and returns a normalised copy of it: every optional field present, every
## number a float, every position three of them.
##
## [b]A copy, so the builder never sees what a mapper wrote.[/b] It sees what this said the
## mapper meant — which is the one version a client is also sent — so a missing `yaw` is 0.0
## on both ends rather than "absent" on one and "0" on the other.
static func validate(source: Dictionary) -> DotResult:
	var doc := source.duplicate(true)

	if int(doc.get("format", 0)) != FORMAT:
		return _refuse("format is %s; this build reads %d" % [str(doc.get("format")), FORMAT], doc)

	# Back to an int: JSON has one number type, and a document that came over the wire would
	# otherwise say 1.0 where the server's said 1, and the two digests would disagree.
	doc["format"] = FORMAT

	var kind := str(doc.get("kind", ""))

	if kind != KIND_COURSE:
		return _refuse("kind is \"%s\"; it is \"course\"" % kind, doc)

	var id := str(doc.get("id", ""))

	if not _is_id(id):
		return _refuse("id \"%s\" is not lowercase a-z, 0-9 and _" % id, doc)

	doc["id"] = id
	doc["name"] = str(doc.get("name", id))
	doc["author"] = str(doc.get("author", ""))
	doc["blurb"] = str(doc.get("blurb", ""))
	doc["theme"] = _theme(doc.get("theme", {}))
	doc["kill_height"] = float(doc.get("kill_height", -12.0))
	doc["round_seconds"] = float(doc.get("round_seconds", 0.0))

	var pieces: Variant = doc.get("pieces", [])

	if typeof(pieces) != TYPE_ARRAY or (pieces as Array).is_empty():
		return _refuse("it has no pieces", doc)

	if (pieces as Array).size() > MAX_PIECES:
		return _refuse("it has %d pieces; the most is %d" % [(pieces as Array).size(), MAX_PIECES], doc)

	var normalised: Array = []

	for index in range((pieces as Array).size()):
		var checked := _piece((pieces as Array)[index], index)

		if not checked.ok:
			return checked.wrap("course %s" % id)

		normalised.append(checked.value)

	doc["pieces"] = normalised

	# A destination inside a pad would send whoever lands straight on, every tick, for ever.
	for pad: Dictionary in normalised:
		if str(pad["kind"]) != "teleport":
			continue

		for other: Dictionary in normalised:
			if str(other["kind"]) == "teleport" and pad_contains(other, pad["to"]):
				return _refuse("a teleport lands inside a teleport (at %s)" % pad["to"], doc)

		var why := _bad_destination(pad, normalised, float(doc["kill_height"]))

		if why != "":
			return _refuse(why, doc)

	var traps: Variant = doc.get("traps", [])

	if typeof(traps) != TYPE_ARRAY:
		return _refuse("`traps` is not a list", doc)

	if (traps as Array).size() > MAX_TRAPS:
		return _refuse("it has %d traps; the most is %d" % [(traps as Array).size(), MAX_TRAPS], doc)

	var checked_traps: Array = []
	var seen := {}

	for index in range((traps as Array).size()):
		var trap := _trap((traps as Array)[index], index)

		if not trap.ok:
			return trap.wrap("course %s" % id)

		var trap_id := str((trap.value as Dictionary)["id"])

		if seen.has(trap_id):
			return _refuse("two traps are called %s" % trap_id, doc)

		seen[trap_id] = true
		checked_traps.append(trap.value)

	doc["traps"] = checked_traps

	# Toys: dot-props' DotPropToyBox placements, `{toy, at, yaw}`. Which ids exist is the
	# catalogue's to say when the map is built (an unknown one is left out and listed), so a map
	# with a toy a newer dot-props has still plays on an older server.
	var toys: Array = []
	for raw: Variant in doc.get("toys", []):
		var toy := DotPropToyBox.normal_placement(raw)
		if toy.is_empty():
			return _refuse("toy %d is not {toy, at}" % toys.size(), doc)
		toys.append(toy)

	if toys.size() > MAX_TOYS:
		return _refuse("%d toys; the most is %d" % [toys.size(), MAX_TOYS], doc)

	doc["toys"] = toys

	var rest := _places(doc)

	if not rest.ok:
		return rest.wrap("course %s" % id)

	return DotResult.success(doc)


## The places a round puts people: the runners' start, the activators' corridor, the finish
## line, and the two ends of the arena.
static func _places(doc: Dictionary) -> DotResult:
	for key: String in ["start", "activators", "finish"]:
		var area: Variant = doc.get(key)

		if typeof(area) != TYPE_DICTIONARY or not (area as Dictionary).has("at"):
			return DotResult.fail(DotError.CODE_INVALID, "A course needs a `%s`: {at, size, yaw}." % key)

		doc[key] = _area(area as Dictionary, Vector3(8.0, 3.0, 6.0) if key == "finish" else Vector3(8.0, 3.0, 6.0))

	var end: Variant = doc.get("end")

	if typeof(end) != TYPE_DICTIONARY:
		return DotResult.fail(
			DotError.CODE_INVALID, "A course needs an `end`: {runners, activators}, the arena's two sides."
		)

	var normalised_end := {}

	for side: String in ["runners", "activators"]:
		var area: Variant = (end as Dictionary).get(side)

		if typeof(area) != TYPE_DICTIONARY or not (area as Dictionary).has("at"):
			return DotResult.fail(DotError.CODE_INVALID, "The end needs a `%s` area." % side)

		normalised_end[side] = _area(area as Dictionary, Vector3(6.0, 3.0, 4.0))

	doc["end"] = normalised_end

	var route: Array = []

	for entry: Variant in doc.get("route", []):
		if typeof(entry) != TYPE_DICTIONARY or not (entry as Dictionary).has("at"):
			return DotResult.fail(DotError.CODE_INVALID, "A route point needs an `at`.")

		route.append({
			"at": _v3((entry as Dictionary)["at"]),
			"jump": bool((entry as Dictionary).get("jump", false)),
			"walk": bool((entry as Dictionary).get("walk", false)),
			"crouch": bool((entry as Dictionary).get("crouch", false)),
			"reach": float((entry as Dictionary).get("reach", 1.2)),
		})

	doc["route"] = route

	# The walkway: the path a stand-in activator walks, for a course whose buttons are not on one
	# straight line. A point with a `button` (a trap id) is where to stand to press that trap.
	var walkway: Array = []

	for entry: Variant in doc.get("walkway", []):
		if typeof(entry) != TYPE_DICTIONARY or not (entry as Dictionary).has("at"):
			return DotResult.fail(DotError.CODE_INVALID, "A walkway point needs an `at`.")

		walkway.append({
			"at": _v3((entry as Dictionary)["at"]),
			"button": str((entry as Dictionary).get("button", "")),
			"reach": float((entry as Dictionary).get("reach", 1.0)),
		})

	doc["walkway"] = walkway
	return DotResult.success(doc)


## An area: `at` is the middle of its FLOOR, `size` is width, height and depth, and `yaw` is
## which way somebody put in it faces (0 is -Z, the way a course runs).
static func _area(source: Dictionary, default_size: Vector3) -> Dictionary:
	return {
		"at": _v3(source["at"]),
		"size": _v3(source.get("size", [default_size.x, default_size.y, default_size.z])),
		"yaw": float(source.get("yaw", 0.0)),
	}


static func _piece(source: Variant, index: int) -> DotResult:
	if typeof(source) != TYPE_DICTIONARY:
		return DotResult.fail(DotError.CODE_INVALID, "Piece %d is not an object." % index)

	var piece := (source as Dictionary).duplicate(true)
	var kind := str(piece.get("kind", ""))

	if not PIECES.has(kind):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Piece %d is a \"%s\", which this build does not know." % [index, kind],
			"known: %s" % ", ".join(PIECES.keys())
		)

	for field: String in PIECES[kind]:
		if not piece.has(field):
			return DotResult.fail(
				DotError.CODE_INVALID, "Piece %d (%s) has no `%s`." % [index, kind, field]
			)

	var role := str(piece.get("role", "hazard" if kind == "kill" else ("safe" if kind == "teleport" else "deck")))

	if not ROLES.has(role):
		return DotResult.fail(
			DotError.CODE_INVALID, "Piece %d has role \"%s\"." % [index, role],
			"roles: %s" % ", ".join(ROLES)
		)

	var out := {"kind": kind, "role": role, "yaw": float(piece.get("yaw", 0.0))}

	# A still piece may be a collider with nothing drawn: a clip, the invisible wall over a
	# railing that keeps an activator out of the runners' corridor while letting them see it.
	if piece.has("visible"):
		out["visible"] = bool(piece["visible"])

	# A pad may be for one side only: the runners' way on is not the activator's.
	if kind == "teleport":
		var side := str(piece.get("for", ""))

		if side != "" and side != "runners" and side != "activators":
			return DotResult.fail(DotError.CODE_INVALID, "Piece %d is a teleport for \"%s\"." % [index, side], "for: runners, activators or nothing")

		out["for"] = side
		# Whether velocity goes through with them, and whether the pad is a floor (a trigger
		# volume is not: it is walked into, like a doorway the map teleports through).
		out["keep"] = bool(piece.get("keep", false))
		out["solid"] = bool(piece.get("solid", true))

	if kind == "kill":
		var look := str(piece.get("look", "spikes"))

		if look != "none" and not LOOKS.has(look):
			return DotResult.fail(DotError.CODE_INVALID, "Piece %d looks like \"%s\"." % [index, look])

		out["look"] = look

	# Every field this build reads, normalised, and nothing else. A field it does not read
	# would travel to every client and be ignored by both ends.
	for key: String in piece:
		match key:
			"kind", "role", "yaw", "look", "visible", "for", "keep", "solid":
				pass
			"at", "from", "to", "size":
				out[key] = _v3(piece[key])
			"tint":
				out[key] = _colour(piece[key], Color.WHITE)
			"phase", "radius", "height", "speed", "pitch", "period", "thickness", "heading":
				out[key] = float(piece[key])
			_:
				pass

	if out.has("period") and float(out["period"]) <= 0.05:
		return DotResult.fail(DotError.CODE_INVALID, "Piece %d has a period of %s." % [index, out["period"]])

	if out.has("size"):
		var size: Vector3 = out["size"]

		if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
			return DotResult.fail(DotError.CODE_INVALID, "Piece %d has a size of %s." % [index, size])

	return DotResult.success(out)


## One trap: what the activator presses, and what moves when they do.
##
## [b]A trap is parts on a timeline, not a kind with a behaviour.[/b] A trapdoor, a crusher, a
## spike wall, a bridge that rolls over and a floor of fire are all "these boxes go from here
## to there and back on this schedule, and these ones kill" — so a mapper builds a new trap
## out of the same five fields rather than waiting for a release that adds it, and the
## validator, the builder and the death test each have one case rather than one per kind.
static func _trap(source: Variant, index: int) -> DotResult:
	if typeof(source) != TYPE_DICTIONARY:
		return DotResult.fail(DotError.CODE_INVALID, "Trap %d is not an object." % index)

	var trap: Dictionary = source
	var id := str(trap.get("id", "trap_%d" % index))

	if not _is_id(id):
		return DotResult.fail(DotError.CODE_INVALID, "Trap %d is called \"%s\"." % [index, id])

	var button: Variant = trap.get("button")

	if typeof(button) != TYPE_DICTIONARY or not (button as Dictionary).has("at"):
		return DotResult.fail(
			DotError.CODE_INVALID, "Trap %s has no button: {at, yaw} where the activator presses it." % id
		)

	var timing: Dictionary = trap.get("timing", {}) if typeof(trap.get("timing", {})) == TYPE_DICTIONARY else {}

	var out := {
		"id": id,
		"name": str(trap.get("name", id.replace("_", " "))),
		"button": {
			"at": _v3((button as Dictionary)["at"]),
			"yaw": float((button as Dictionary).get("yaw", 0.0)),
		},
		# Seconds from one press until the button can be pressed again. 0 is once a round,
		# which is what the servers this game is modelled on do with almost every trap.
		"cooldown": maxf(float(trap.get("cooldown", 0.0)), 0.0),
		# What it sounds like when it goes: one of [constant TRAP_SOUNDS], or "" for the game
		# to tell from what its parts do (DrAudio.trap_sound). A name this build does not have
		# is "" rather than a refusal: a sound is never a reason a course will not load.
		"sound": str(trap.get("sound", "")) if TRAP_SOUNDS.has(str(trap.get("sound", ""))) else "",
		"timing": {
			"delay": maxf(float(timing.get("delay", 0.0)), 0.0),
			# The share of the delay that is the server's tell (DrGame.with_tell), kept so a
			# client knows how long to flash the parts for.
			"tell": maxf(float(timing.get("tell", 0.0)), 0.0),
			"out": maxf(float(timing.get("out", 0.3)), 0.0),
			# Negative stays out for the rest of the round: a floor that falls and does not
			# come back.
			"hold": float(timing.get("hold", 2.0)),
			"back": maxf(float(timing.get("back", 1.0)), 0.0),
		},
	}

	var parts: Variant = trap.get("parts", [])

	if typeof(parts) != TYPE_ARRAY or (parts as Array).is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "Trap %s moves nothing: it has no parts." % id)

	if (parts as Array).size() > MAX_PARTS:
		return DotResult.fail(DotError.CODE_INVALID, "Trap %s has %d parts; the most is %d." % [
			id, (parts as Array).size(), MAX_PARTS])

	var checked: Array = []

	for part_index in range((parts as Array).size()):
		var part := _part((parts as Array)[part_index], id, part_index)

		if not part.ok:
			return part

		checked.append(part.value)

	out["parts"] = checked

	# Where a runner stands to be caught by this trap. Read by nothing in a round: the course
	# suite stands somebody here, presses, and fails a trap that lets them live — which is how
	# a trapdoor whose leaves swung UP would be found before anybody played it.
	if trap.has("victim"):
		out["victim"] = _v3(trap["victim"])

	# And where a runner stands to be MISSED by it: a trap that is dodged rather than jumped
	# (a swinging blade misses the walls) is only half tested by its victim, and a blade that
	# swept the whole corridor would pass that half. Read by nothing in a round either.
	if trap.has("spared"):
		out["spared"] = _v3(trap["spared"])

	var zone: Variant = trap.get("zone")

	if typeof(zone) == TYPE_DICTIONARY and (zone as Dictionary).has("at"):
		out["zone"] = {
			"at": _v3((zone as Dictionary)["at"]),
			"size": _v3((zone as Dictionary).get("size", [4.0, 3.0, 4.0])),
		}

	return DotResult.success(out)


static func _part(source: Variant, trap_id: String, index: int) -> DotResult:
	if typeof(source) != TYPE_DICTIONARY or not (source as Dictionary).has("at") \
			or not (source as Dictionary).has("size"):
		return DotResult.fail(
			DotError.CODE_INVALID, "Part %d of trap %s needs an `at` and a `size`." % [index, trap_id]
		)

	var part: Dictionary = source
	var look := str(part.get("look", "block"))

	if not LOOKS.has(look):
		return DotResult.fail(DotError.CODE_INVALID, "Part %d of trap %s looks like \"%s\"." % [
			index, trap_id, look], "looks: %s" % ", ".join(LOOKS))

	var face := str(part.get("face", "up"))

	if not FACES.has(face):
		return DotResult.fail(DotError.CODE_INVALID, "Part %d of trap %s faces \"%s\"." % [
			index, trap_id, face], "faces: %s" % ", ".join(FACES))

	# A floor that is part of a trap is drawn as floor unless the mapper says otherwise: a
	# trapdoor in the moving-ground colour is a trapdoor every runner walks round, which is the
	# trap disarmed by its paint. Killers are drawn as hazards, because they are only ever seen
	# when they are out.
	var role := str(part.get("role", "hazard" if bool(part.get("lethal", false)) else "deck"))

	if not ROLES.has(role):
		return DotResult.fail(DotError.CODE_INVALID, "Part %d of trap %s has role \"%s\"." % [
			index, trap_id, role])

	var size := _v3(part["size"])

	if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "Part %d of trap %s has a size of %s." % [
			index, trap_id, size])

	var lethal := bool(part.get("lethal", false))
	# Solid unless it kills. A part that kills AND is solid is a part that pushes somebody out of
	# itself before the death test finds them inside it — and pushing depends on the order two
	# bodies were resolved in, which two machines do not agree on.
	# A push zone (a fan, a wind tunnel) is a volume, never a wall: same reasoning, and a body in
	# the way of the wind would stop the very player it pushes.
	var push := _v3(part.get("push", [0.0, 0.0, 0.0]))
	var solid := bool(part.get("solid", not lethal and push == Vector3.ZERO))

	var out := {
		"at": _v3(part["at"]),
		"size": size,
		"yaw": float(part.get("yaw", 0.0)),
		"pitch": float(part.get("pitch", 0.0)),
		"role": role,
		"look": look,
		"face": face,
		"lethal": lethal,
		"solid": solid,
		"move": _v3(part.get("move", [0.0, 0.0, 0.0])),
		"spin": float(part.get("spin", 0.0)),
		"push": push,
	}

	var turn: Variant = part.get("turn")

	if typeof(turn) == TYPE_DICTIONARY:
		var axis := str((turn as Dictionary).get("axis", "z"))

		if not ["x", "y", "z"].has(axis):
			return DotResult.fail(DotError.CODE_INVALID, "Part %d of trap %s turns about \"%s\"." % [
				index, trap_id, axis])

		out["turn"] = {
			"axis": axis,
			"degrees": float((turn as Dictionary).get("degrees", 90.0)),
			"pivot": _v3((turn as Dictionary).get("pivot", part["at"])),
		}

	if part.has("tint"):
		out["tint"] = _colour(part["tint"], Color.WHITE)

	return DotResult.success(out)


static func _theme(source: Variant) -> Dictionary:
	var theme: Dictionary = source if typeof(source) == TYPE_DICTIONARY else {}

	var normal := {
		"sky": _colour(theme.get("sky"), Color(0.48, 0.60, 0.74)),
		"horizon": _colour(theme.get("horizon"), Color(0.80, 0.85, 0.90)),
		"void": _colour(theme.get("void"), Color(0.10, 0.12, 0.16)),
		"sun": _colour(theme.get("sun"), Color(1.0, 0.97, 0.92)),
		"deck": _colour(theme.get("deck"), Color.WHITE),
		"fog": float(theme.get("fog", 0.004)),
	}

	# A surface skin (DrTextures), written only when the course names one: a document without it
	# normalises exactly as before, so no baked course's fingerprint moves.
	var skin := str(theme.get("surface", "")).strip_edges().to_lower()

	if skin != "" and skin.is_valid_filename() and not skin.contains("."):
		normal["surface"] = skin

	return normal


# --- The wire ---------------------------------------------------------------

## A normalised document as bytes: JSON, deflated, behind both its lengths.
##
## [b]The NORMALISED document, never the file.[/b] The server encodes what [method validate]
## returned and a client validates what it decodes, so both ends build from the same
## dictionary — and a client whose build is a format behind refuses it with a sentence rather
## than building a course with holes in it.
static func encode(doc: Dictionary) -> PackedByteArray:
	var text := JSON.stringify(_to_plain(doc), "", true)
	var raw := text.to_utf8_buffer()
	var packed := raw.compress(FileAccess.COMPRESSION_DEFLATE)

	var out := PackedByteArray()
	out.resize(8)
	out.encode_u32(0, raw.size())
	out.encode_u32(4, packed.size())
	out.append_array(packed)
	return out


static func decode(bytes: PackedByteArray) -> DotResult:
	if bytes.size() < 9:
		return DotResult.fail(DotError.CODE_PARSE, "A course on the wire was empty.")

	var size := bytes.decode_u32(0)

	# Both lengths, so a torn or padded body is refused here rather than handed to the
	# decompressor, which prints an engine error for it before returning nothing.
	if bytes.decode_u32(4) != bytes.size() - 8:
		return DotResult.fail(DotError.CODE_PARSE, "A course on the wire is not the length it says.")

	# A size this large is a corrupt header or somebody else's bytes; decompressing it would
	# allocate whatever it says.
	if size <= 0 or size > WIRE_LIMIT * 16:
		return DotResult.fail(DotError.CODE_PARSE, "A course on the wire says it is %d bytes." % size)

	var raw := bytes.slice(8).decompress(size, FileAccess.COMPRESSION_DEFLATE)

	if raw.size() != size:
		return DotResult.fail(DotError.CODE_PARSE, "A course on the wire would not decompress.")

	return parse_json(raw.get_string_from_utf8(), "wire")


## A short fingerprint of a document, for a log line and for two ends to compare.
static func digest(doc: Dictionary) -> String:
	return JSON.stringify(_to_plain(doc), "", true).sha256_text().substr(0, 12)


## A validated document as JSON text a mapper's file could hold: [method parse_json] reads it
## back. What a suite or a render writes as a pack's course.
static func to_json(doc: Dictionary) -> String:
	return JSON.stringify(_to_plain(doc))


## Vectors and colours back to arrays, so JSON can carry them.
static func _to_plain(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			var out := {}
			for key: Variant in value:
				out[key] = _to_plain(value[key])
			return out
		TYPE_ARRAY:
			var out := []
			for item: Variant in value:
				out.append(_to_plain(item))
			return out
		TYPE_VECTOR3:
			var v: Vector3 = value
			return [v.x, v.y, v.z]
		TYPE_VECTOR2:
			var v: Vector2 = value
			return [v.x, v.y]
		TYPE_COLOR:
			var c: Color = value
			return [c.r, c.g, c.b]
		_:
			return value


# --- Small readers ----------------------------------------------------------

static func _v3(value: Variant) -> Vector3:
	if value is Vector3:
		return value

	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))

	return Vector3.ZERO


static func _colour(value: Variant, fallback: Color) -> Color:
	if value is Color:
		return value

	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		return Color(float(value[0]), float(value[1]), float(value[2]))

	if typeof(value) == TYPE_STRING and Color.html_is_valid(str(value)):
		return Color.html(str(value))

	return fallback


static func _is_id(id: String) -> bool:
	if id.is_empty() or id.length() > 48:
		return false

	for character in id:
		if not (character >= "a" and character <= "z") and not (character >= "0" and character <= "9") \
				and character != "_":
			return false

	return true


static func _refuse(why: String, doc: Dictionary) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INVALID, "The document is refused: %s." % why, str(doc.get("id", "?"))
	)


## Whether [param feet] is in the teleport [param spec] (a validated piece). A solid pad takes
## feet within its footprint and between a little under its top and a metre over it. A trigger
## volume (`solid` false) is the map's own box grown by a player's body, the way a brush trigger
## is touched: 0.4 m sideways and 1.8 m down, because a thin pane at chest height is walked
## through by feet that never reach it. Here and not in DrCourse because the validator asks it of
## every destination and DrCourse already preloads this file.
static func pad_contains(spec: Dictionary, feet: Vector3) -> bool:
	var size: Vector3 = spec["size"]
	var local := Basis(Vector3.UP, deg_to_rad(float(spec["yaw"]))).inverse() * (feet - (spec["at"] as Vector3))
	var solid := bool(spec.get("solid", true))
	var sideways := 0.0 if solid else BODY_RADIUS

	if absf(local.x) > size.x * 0.5 + sideways or absf(local.z) > size.z * 0.5 + sideways:
		return false

	if solid:
		return local.y >= size.y * 0.5 - 0.3 and local.y <= size.y * 0.5 + 1.0

	return local.y >= -size.y * 0.5 - BODY_HEIGHT and local.y <= size.y * 0.5

## Why a teleport's destination is a bad one, or "". Beyond a landing inside a teleport (checked by the
## caller): above a solid pad (they fall back onto it, a loop), inside solid geometry or below the kill
## height (dead on arrival), and, for `keep`, within [constant KEEP_REACH] metres of a volume along the
## heading (the carried speed takes them into it).
static func _bad_destination(pad: Dictionary, pieces: Array, kill_height: float) -> String:
	var to: Vector3 = pad["to"]

	if to.y < kill_height:
		return "a teleport lands below the kill height (at %s)" % to

	for other: Dictionary in pieces:
		var kind := str(other["kind"])

		if kind != "box" and not (kind == "teleport" and bool(other.get("solid", true))):
			continue

		var size: Vector3 = other["size"]
		var local := Basis(Vector3.UP, deg_to_rad(float(other["yaw"]))).inverse() * (to - (other["at"] as Vector3))

		if absf(local.x) >= size.x * 0.5 or absf(local.z) >= size.z * 0.5:
			continue

		if kind == "teleport" and local.y >= size.y * 0.5:
			return "a teleport lands above a solid teleport pad, and falls back onto it (at %s)" % to

		if local.y > -size.y * 0.5 and local.y < size.y * 0.5 - 0.05:
			return "a teleport lands inside solid geometry (at %s)" % to

	if bool(pad.get("keep", false)):
		var ahead := Vector3(-sin(deg_to_rad(float(pad.get("heading", 0.0)))), 0.0, -cos(deg_to_rad(float(pad.get("heading", 0.0)))))

		for other: Dictionary in pieces:
			if str(other["kind"]) != "teleport" or bool(other.get("solid", true)):
				continue

			for step in range(0, int(KEEP_REACH / 0.5) + 1):
				if pad_contains(other, to + ahead * (0.5 * step)):
					return "a teleport that keeps speed lands within %.0f m of a teleport volume ahead (at %s)" % [KEEP_REACH, to]

	return ""


## How far ahead of a `keep` destination a volume may not be (metres): a player carrying speed.
const KEEP_REACH := 8.0

## A player's half width and height, for a trigger volume (see [method pad_contains]).
const BODY_RADIUS := 0.4
const BODY_HEIGHT := 1.8
