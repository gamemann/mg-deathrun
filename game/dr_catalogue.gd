extends RefCounted

const DrCourseDoc := preload("dr_course_doc.gd")
const DrPaths := preload("dr_paths.gd")

## Every course this server can play, and which one is next.
##
## [b]Two sources, and the built-in one is a floor rather than a feature.[/b] The courses are
## documents read from [member DrConfig.course_directory] — `courses/` in this repository, a
## directory in a delivered pack. A server whose directory is missing or empty still has
## [method practice], so it plays rather than refusing to start.
##
## [b]A server reads documents; a client never does.[/b] The course travels in the round's
## first event (see [DrCourseDoc]), so nothing here runs on a connected client.

const CHANNEL := "dr.catalogue"

const PRACTICE := &"dr_practice"

## id -> normalised document.
var courses: Dictionary = {}

## Files that were refused, with why. What `dr_courses` prints, so a mapper can see it.
var refused: Dictionary = {}

## id -> pack title, for the courses in [member courses] that a subscribed pack provided (solo
## only). The game's own courses are never in it, and an id of theirs is never taken by a pack.
var workshop: Dictionary = {}

## The Workshop's index and the `map_kind`s taken from it; see [method follow_content].
var content_index: DotContentIndex = null
var content_kinds: PackedStringArray = PackedStringArray()

## The order courses come up in when they are not shuffled.
var _order: Array[StringName] = []
var _next: int = 0

## The server's maps.yml, or null when there is none (every course rotates, as it always did).
## dot-map's rotation file speaks DotMapDef; this catalogue holds course documents, so [member _defs]
## mirrors the ids (built-in, directory, delivered pack and Workshop alike) and the file marks
## `in_rotation` on the mirror. See [method rotating].
var rotation_file: DotMapRotationFile = null
var _defs: DotMapCatalogue = DotMapCatalogue.new()
var _rotation: DotMapRotation = DotMapRotation.of(_defs)
var _workshop_docs: Dictionary = {}


## Reads every document under [param directory] (relative to this game's root), and adds the
## one built in. Forgets anything read before.
func load_from(directory: String) -> int:
	courses.clear()
	refused.clear()
	workshop.clear()

	_add(practice(), "built-in")

	var root := DrPaths.rebase("res://" + directory.trim_prefix("res://").trim_prefix("/"))
	var loaded := _read_directory(root)
	_rebuild_order()

	DotLog.info(CHANNEL, "courses loaded", {"courses": courses.size(), "refused": refused.size()})
	return loaded


## Adds every document under [param root] — an absolute `res://` path — to what is already
## loaded. What a server uses for a course pack mounted beside the game: such a pack mounts at
## its OWN prefix, so the rebasing this game's own paths need would put it in the wrong place.
func add_directory(root: String) -> int:
	var loaded := _read_directory(root)
	_rebuild_order()

	DotLog.info(CHANNEL, "courses added", {"from": root, "read": loaded, "courses": courses.size()})
	return loaded


func _read_directory(root: String) -> int:
	var dir := DirAccess.open(root)

	if dir == null:
		DotLog.info(CHANNEL, "no course directory here", {"looked_at": root})
		return 0

	var files := PackedStringArray()

	for file in dir.get_files():
		# Anything that is not a document is somebody's README.
		if file.ends_with(".json"):
			files.append(file)

	# Sorted, so the order a server plays them in does not depend on the filesystem.
	files.sort()

	var loaded := 0

	for file in files:
		var path := root.path_join(file)
		var text := FileAccess.get_file_as_string(path)

		if text.is_empty():
			refused[file] = "empty or unreadable"
			continue

		var parsed := DrCourseDoc.parse_json(text, file)

		if not parsed.ok:
			refused[file] = parsed.error.message
			# WARN: a server is running without a course somebody installed, and the mapper
			# needs the sentence. Not ERROR: every other course still plays.
			DotLog.warn(CHANNEL, "a document was refused", {
				"file": file, "why": parsed.error.message, "detail": parsed.error.detail,
			})
			continue

		if _add(parsed.value, file):
			loaded += 1

	return loaded


func _add(doc: Dictionary, origin: String) -> bool:
	var id := StringName(str(doc["id"]))

	if courses.has(id) and origin != "built-in" and id != PRACTICE:
		# A file named after the built-in replaces it, which is how a server improves on the
		# practice course without a code change. Two FILES with one id is a mistake.
		refused[origin] = "a second document with id %s" % id
		return false

	courses[id] = doc
	return true


func _rebuild_order() -> void:
	_order.clear()

	for id: StringName in courses:
		_order.append(id)

	_order.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	_next = 0


## Takes the courses subscribed packs provide, for the index's current session only. Opt-in.
## A pack's map is a [b]course document[/b] (the JSON `courses/` holds, see its README) named
## by the entry's `scene` path, with `map_kind` one of [param accepted_kinds] ("*" is every kind,
## empty none). The document is the whole map: the traps, the buttons, the runners' start and
## the activators' walkway all come from it, so a pack ships no code and the game needs no
## second format.
##
## [b]Synced on every read rather than copied once[/b]: the index filters by its current
## session, so a game that goes online loses them with no signal to miss.
## [method playable_courses] is the read everything goes through.
func follow_content(index: DotContentIndex, accepted_kinds: PackedStringArray = PackedStringArray()) -> void:
	content_index = index
	content_kinds = accepted_kinds
	sync_content()


## Brings [member courses] in line with the index's current session: a pack course in, one that
## left out. The game's own ids win, and a pack course that is not a valid document is listed in
## [member refused] and left out.
func sync_content() -> void:
	var wanted := {}

	if content_index != null:
		for entry in content_index.entries(&"map"):
			var kind := str(entry.raw.get("map_kind", ""))

			if kind == "" or not (content_kinds.has("*") or content_kinds.has(kind)):
				continue

			var id := StringName(entry.id)

			if wanted.has(id) or (courses.has(id) and not workshop.has(id)):
				continue

			var doc := _workshop_doc(entry)

			if not doc.is_empty():
				wanted[id] = [doc, entry.pack_title]

	var changed := false

	for id: StringName in workshop.keys():
		if not wanted.has(id):
			courses.erase(id)
			workshop.erase(id)
			changed = true

	for id: StringName in wanted:
		if not courses.has(id):
			courses[id] = wanted[id][0]
			workshop[id] = wanted[id][1]
			changed = true

	if changed:
		_rebuild_order()


func _workshop_doc(entry: DotContentEntry) -> Dictionary:
	if _workshop_docs.has(entry.key):
		return _workshop_docs[entry.key]

	var path := entry.path("scene")
	var text := FileAccess.get_file_as_string(path) if path != "" else ""
	var parsed := DrCourseDoc.parse_json(text, path) if text != "" \
		else DotResult.fail(DotError.CODE_IO, "empty or unreadable", path)
	var doc: Dictionary = {}

	if parsed.ok:
		doc = parsed.value
		doc["id"] = entry.id
	else:
		refused[entry.key] = parsed.error.message
		DotLog.warn(CHANNEL, "a Workshop course was refused", {
			"entry": entry.key, "why": parsed.error.message,
		})

	_workshop_docs[entry.key] = doc
	return doc


## The file a game pack states what it takes from subscriptions in (dot-cloud's
## docs/workshop.md, "What a game accepts"). Read from there so the site and this list cannot drift.
const PROVIDES_PATH := "res://provides.json"
const ACCEPTED_MAP_KINDS_FALLBACK := ["deathrun"]


## The `map_kind`s of subscribed maps this game takes: `accepts.map_kinds` in `provides.json`.
static func accepted_map_kinds() -> PackedStringArray:
	var out := PackedStringArray()
	var path := DrPaths.rebase(PROVIDES_PATH)
	var parsed: Variant = null
	if FileAccess.file_exists(path):
		parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	var accepts: Variant = (parsed as Dictionary).get("accepts") if parsed is Dictionary else null
	var kinds: Variant = (accepts as Dictionary).get("map_kinds") if accepts is Dictionary else null
	if not (kinds is Array):
		kinds = ACCEPTED_MAP_KINDS_FALLBACK
	for kind: Variant in (kinds as Array):
		out.append(str(kind))
	return out


## Whether [param id] came from a subscribed pack.
func is_workshop(id: StringName) -> bool:
	return workshop.has(id)


## The name a menu shows: "Name [Pack]" for a pack's course, the plain name otherwise.
func label_of(id: StringName) -> String:
	var name := str((courses.get(id, {}) as Dictionary).get("name", id))
	var pack := str(workshop.get(id, ""))
	return "%s [%s]" % [name, pack] if pack != "" else name


## The ids a server may draw from, after [param allowed] (empty is all). The built-in practice
## course drops out once there is anything else.
func playable_courses(allowed: PackedStringArray) -> Array[StringName]:
	sync_content()
	var out: Array[StringName] = []

	for id in _order:
		if allowed.is_empty() or allowed.has(String(id)):
			out.append(id)

	if allowed.is_empty() and out.size() > 1:
		out.erase(PRACTICE)

	return out


## Whether maps.yml names rotations, so that it (not `shuffle_courses`) orders the courses.
func has_rotation_file() -> bool:
	return rotation_file != null and rotation_file.has_rotations()


## Brings the mirror up to date with [member courses] and lets the file mark who rotates.
## Without a file every course is in, which is what [method playable_courses] always did.
func apply_rotation(allowed: PackedStringArray = PackedStringArray()) -> void:
	sync_content()
	var seen := {}

	for id: StringName in _order:
		seen[id] = true
		var def := _defs.get_map(id)

		if def == null:
			def = DotMapDef.new()
			def.id = id
			def.scene_path = "dr:%s" % id
			def.display_name = str((courses.get(id, {}) as Dictionary).get("name", id))
			var _added := _defs.add(def)

		def.enabled = allowed.is_empty() or allowed.has(String(id))

	for def: DotMapDef in _defs.maps.duplicate():
		if not seen.has(def.id):
			var _gone := _defs.remove(def.id)

	if has_rotation_file():
		# A file that names rotations leaves the practice course out unless it is all there is.
		# Captures the mirror, never self: a lambda on self held by a member is a reference cycle,
		# and a RefCounted cycle is a leak the exit check reports.
		var mirror := _defs
		rotation_file.fallback_in = func(def: DotMapDef) -> bool:
			return def.id != PRACTICE or mirror.size() == 1
		var _applied := rotation_file.apply(_rotation)
		return

	_rotation.order = []

	for def: DotMapDef in _defs.maps:
		def.in_rotation = true


## `dr_rotation <name>`: the live switch to another named rotation in the file.
func switch_rotation(rotation_name: String) -> DotResult:
	if not has_rotation_file():
		return DotResult.fail(DotError.CODE_STATE, "There is no maps.yml to switch rotations in.")

	apply_rotation()
	return rotation_file.switch(_rotation, rotation_name)


## Whether [param id] is in the active rotation. A course the catalogue does not hold is not.
func in_rotation(id: StringName) -> bool:
	if not courses.has(id):
		return false

	if not has_rotation_file():
		return true

	apply_rotation()
	var def := _defs.get_map(id)
	return def != null and def.in_rotation


## What the ballot, a nomination and the next-course draw may offer: [method playable_courses]
## less the courses maps.yml leaves out. A course left out stays [i]playable[/i] (the map menu
## and an admin's change load it). With no file, or a file that leaves nothing, it is
## [method playable_courses].
func rotating(allowed: PackedStringArray) -> Array[StringName]:
	var every := playable_courses(allowed)

	if not has_rotation_file():
		return every

	apply_rotation(allowed)
	var out: Array[StringName] = []

	for id in every:
		var def := _defs.get_map(id)

		if def != null and def.in_rotation:
			out.append(id)

	return out if not out.is_empty() else every


## Records that [param id] was built, for the file's cooldown and cycle. Nothing without a file.
func note_played(id: StringName) -> void:
	if has_rotation_file() and courses.has(id):
		_rotation.note_played(id)


## The next course: drawn from [param stream] when shuffling, in order otherwise. A maps.yml with
## rotations replaces both: its rotation's mode (`random` with a cooldown, or `cycle`) and
## written order decide.
##
## [b]Never the same course twice running when there is a choice[/b], because a shuffle that
## repeats is the thing every player notices first and reports as the rotation being broken.
func next_course(allowed: PackedStringArray, shuffle: bool, stream: DotRandomStream,
		previous: StringName) -> Dictionary:
	if has_rotation_file():
		apply_rotation(allowed)

		if _rotation.seed_value == 0 and stream != null:
			_rotation.seed_value = stream.next_range_i(1, 0x3fffffff)

		var chosen := _rotation.choose(0)

		if chosen != null and courses.has(chosen.id):
			return courses[chosen.id]

	var ids := rotating(allowed)

	if ids.is_empty():
		DotLog.warn(CHANNEL, "no course matches the allowed list; playing practice", {
			"allowed": ",".join(allowed),
		})
		return courses.get(PRACTICE, practice())

	var pick: StringName

	if shuffle and stream != null:
		pick = ids[stream.next_range_i(0, ids.size() - 1)]

		if pick == previous and ids.size() > 1:
			pick = ids[(ids.find(pick) + 1 + stream.next_range_i(0, ids.size() - 2)) % ids.size()]
	else:
		pick = ids[_next % ids.size()]
		_next += 1

	return courses[pick]


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["courses (%d)" % courses.size()])

	for id in _order:
		var doc: Dictionary = courses[id]
		lines.append("  %-22s %-24s %2d traps  %s%s" % [
			id, label_of(id), (doc["traps"] as Array).size(), str(doc["author"]),
			"" if in_rotation(id) else "  (not in rotation)",
		])

	if not refused.is_empty():
		lines.append("refused (%d)" % refused.size())

		for file: String in refused:
			lines.append("  %-22s %s" % [file, refused[file]])

	return lines


# --- The one built in ---------------------------------------------------------

## Five traps of five shapes, a corridor for the activator above them, and a room to settle
## it in.
##
## [b]Written here rather than shipped as a file,[/b] so a server with no course directory at
## all — a fresh clone, a suite — has something to play, and the suites have a course whose
## every number is in front of them. The suites lean on these numbers: the trapdoor is at
## z -10..-16, the spike wall at -19..-23, the crusher at -25.5..-28.5, the stepping blocks at
## -31.5..-39.5 and the fire at -44..-48.
##
## The runners' corridor is six metres wide on x -3..3 with its floor at y 0. The activators'
## walkway runs beside it at y 3, on x 3.75..8.75, level with the top of the runners' right
## wall, so an activator at the rail looks straight down into the corridor; a thin rail and an
## invisible clip above the wall keep them out of it.
static func practice() -> Dictionary:
	var pieces: Array = [
		# The runners' floor, in four lengths with the traps' gaps between them.
		{"kind": "box", "at": [0.0, -0.5, -1.0], "size": [6.0, 1.0, 18.0]},
		{"kind": "box", "at": [0.0, -0.5, -23.0], "size": [6.0, 1.0, 14.0]},
		{"kind": "box", "at": [0.0, -0.5, -45.0], "size": [6.0, 1.0, 10.0]},
		# The back of the start, so the countdown is not spent walking backwards off it.
		{"kind": "box", "at": [0.0, 1.9, 8.25], "size": [7.0, 3.8, 0.5], "role": "pillar"},
		# The left wall, whole.
		{"kind": "box", "at": [-3.5, 1.9, -21.0], "size": [0.5, 3.8, 59.0], "role": "pillar"},
		# The right wall, level with the walkway beside it, with a slot where the spike wall waits.
		{"kind": "box", "at": [3.5, 1.5, -5.5], "size": [0.5, 3.0, 27.0], "role": "pillar"},
		{"kind": "box", "at": [3.5, 1.5, -36.75], "size": [0.5, 3.0, 27.5], "role": "pillar"},
		{"kind": "box", "at": [3.5, 2.5, -21.0], "size": [0.5, 1.0, 4.0], "role": "pillar"},
		# The end of the corridor: the arena is through here, by teleport.
		{"kind": "box", "at": [0.0, 1.9, -50.75], "size": [7.0, 3.8, 0.5], "role": "pillar"},
		# What is under the trapdoor and the stepping blocks.
		{"kind": "kill", "at": [0.0, -5.5, -13.0], "size": [6.0, 1.0, 6.0], "look": "spikes"},
		{"kind": "kill", "at": [0.0, -5.5, -35.0], "size": [6.0, 1.0, 10.0], "look": "spikes"},
		# The activators' walkway, its outer wall, and the clip over the runners' right wall.
		{"kind": "box", "at": [6.25, 2.5, -21.0], "size": [5.0, 1.0, 59.0]},
		{"kind": "box", "at": [9.0, 4.9, -21.0], "size": [0.5, 3.8, 59.0], "role": "pillar"},
		{"kind": "box", "at": [6.25, 4.9, 8.25], "size": [5.0, 3.8, 0.5], "role": "pillar"},
		{"kind": "box", "at": [6.25, 4.9, -50.25], "size": [5.0, 3.8, 0.5], "role": "pillar"},
		{"kind": "box", "at": [3.5, 4.0, -21.0], "size": [0.12, 0.1, 59.0], "role": "cannon"},
		{"kind": "box", "at": [3.5, 5.6, -21.0], "size": [0.5, 5.2, 59.0], "role": "pillar", "visible": false},
		# The end arena, beyond the corridor.
		{"kind": "box", "at": [0.0, -0.5, -64.0], "size": [20.0, 1.0, 20.0], "role": "arena"},
		{"kind": "box", "at": [-10.25, 2.0, -64.0], "size": [0.5, 4.0, 20.0], "role": "pillar"},
		{"kind": "box", "at": [10.25, 2.0, -64.0], "size": [0.5, 4.0, 20.0], "role": "pillar"},
		{"kind": "box", "at": [0.0, 2.0, -53.75], "size": [21.0, 4.0, 0.5], "role": "pillar"},
		{"kind": "box", "at": [0.0, 2.0, -74.25], "size": [21.0, 4.0, 0.5], "role": "pillar"},
		{"kind": "box", "at": [-4.0, 0.75, -64.0], "size": [2.0, 1.5, 2.0], "role": "pillar"},
		{"kind": "box", "at": [4.0, 0.75, -64.0], "size": [2.0, 1.5, 2.0], "role": "pillar"},
	]

	var traps: Array = [
		{
			"id": "trapdoor", "name": "Trapdoor", "victim": [1.4, 0.0, -13.0],
			"button": {"at": [4.6, 3.0, -13.0], "yaw": 90.0},
			"timing": {"out": 0.25, "hold": 3.0, "back": 1.5},
			"parts": [
				# Two leaves hinged at the walls, swinging down: whoever stands on one slides
				# off it into the spikes.
				{"at": [-1.5, -0.25, -13.0], "size": [3.0, 0.5, 6.0],
					"turn": {"axis": "z", "degrees": -95.0, "pivot": [-3.0, -0.25, -13.0]}},
				{"at": [1.5, -0.25, -13.0], "size": [3.0, 0.5, 6.0],
					"turn": {"axis": "z", "degrees": 95.0, "pivot": [3.0, -0.25, -13.0]}},
			],
		},
		{
			"id": "spike_wall", "name": "Spike wall", "victim": [-1.5, 0.0, -21.0],
			"button": {"at": [4.6, 3.0, -21.0], "yaw": 90.0},
			"timing": {"out": 0.35, "hold": 0.8, "back": 1.2},
			"parts": [
				# Two metres tall, and a standing jump is one point two: it is not jumped.
				{"at": [4.05, 1.0, -21.0], "size": [0.6, 2.0, 3.8], "look": "spikes", "face": "left",
					"lethal": true, "move": [-6.75, 0.0, 0.0]},
			],
		},
		{
			"id": "crusher", "name": "Crusher", "victim": [0.5, 0.0, -27.0],
			"button": {"at": [4.6, 3.0, -27.0], "yaw": 90.0},
			"timing": {"out": 0.4, "hold": 0.6, "back": 1.6},
			"parts": [
				{"at": [0.0, 3.4, -27.0], "size": [6.0, 0.8, 3.0], "look": "spikes", "face": "down",
					"lethal": true, "move": [0.0, -3.0, 0.0]},
			],
		},
		{
			"id": "blocks", "name": "Falling blocks", "victim": [1.0, 0.0, -35.5],
			"button": {"at": [4.6, 3.0, -35.5], "yaw": 90.0},
			"timing": {"out": 0.6, "hold": 2.5, "back": 1.5},
			"parts": [
				{"at": [-1.0, -0.25, -32.5], "size": [2.0, 0.5, 2.0], "move": [0.0, -12.0, 0.0]},
				{"at": [1.0, -0.25, -35.5], "size": [2.0, 0.5, 2.0], "move": [0.0, -12.0, 0.0]},
				{"at": [-1.0, -0.25, -38.5], "size": [2.0, 0.5, 2.0], "move": [0.0, -12.0, 0.0]},
			],
		},
		{
			"id": "fire", "name": "Fire", "victim": [0.0, 0.0, -46.0],
			"button": {"at": [4.6, 3.0, -46.0], "yaw": 90.0},
			"timing": {"out": 0.05, "hold": 1.5, "back": 0.05},
			"parts": [
				{"at": [0.0, 0.9, -46.0], "size": [6.0, 1.8, 4.0], "look": "fire", "lethal": true},
			],
		},
	]

	var doc := {
		"format": 1,
		"kind": "course",
		"id": String(PRACTICE),
		"name": "Practice Run",
		"author": "mg-deathrun",
		"blurb": "Five traps, one of each shape, before the real courses.",
		"kill_height": -8.0,
		"theme": {"deck": [0.86, 0.92, 1.0]},
		"pieces": pieces,
		"traps": traps,
		# dot-props' loose toys: a ball in the start room, and two in the arena. headless_run
		# walks into the start's football and shoots the arena's beach ball.
		"toys": [
			{"toy": "football", "at": [1.8, 0.0, 6.5]},
			{"toy": "beach_ball", "at": [-7.0, 0.0, -64.0]},
			{"toy": "tyre", "at": [7.0, 0.0, -68.0], "yaw": 30.0},
		],
		"start": {"at": [0.0, 0.0, 4.5], "size": [6.0, 3.0, 6.0], "yaw": 0.0},
		"activators": {"at": [6.25, 3.0, 5.0], "size": [4.0, 3.0, 4.0], "yaw": 0.0},
		"finish": {"at": [0.0, 0.0, -49.25], "size": [6.0, 3.0, 2.5], "yaw": 0.0},
		"end": {
			"runners": {"at": [0.0, 0.0, -56.5], "size": [8.0, 3.0, 4.0], "yaw": 0.0},
			"activators": {"at": [0.0, 0.0, -71.5], "size": [8.0, 3.0, 4.0], "yaw": 180.0},
		},
		"route": [
			{"at": [0.0, 0.0, -9.0]},
			{"at": [-1.0, 0.0, -32.5], "jump": true, "reach": 0.6},
			{"at": [1.0, 0.0, -35.5], "jump": true, "reach": 0.6},
			{"at": [-1.0, 0.0, -38.5], "jump": true, "reach": 0.6},
			{"at": [0.0, 0.0, -41.5], "jump": true},
			{"at": [0.0, 0.0, -49.25]},
		],
	}

	var checked := DrCourseDoc.validate(doc)

	if not checked.ok:
		# The suite's first check, and the reason it is the first: a built-in course that does
		# not validate is a server with nothing to play.
		push_error("The built-in course does not validate: %s" % checked.error.message)
		return doc

	return checked.value
