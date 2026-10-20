extends Node3D

const DrCourseDoc := preload("dr_course_doc.gd")
const DrTextures := preload("dr_textures.gd")
const DrPaths := preload("dr_paths.gd")

## A course built from its document: the pieces, the traps and their buttons, where every
## moving thing is on a given tick, and the questions a round asks of them.
##
## [b]A trap is a pure function of the tick and the tick it was pressed on.[/b] mg-wipeout's
## obstacles are functions of the tick alone, so nothing about them is ever sent. A trap here
## has one more input — when the activator pressed its button — and that input is the ONLY
## thing about it that travels: one event, a trap and a tick. From those two numbers both ends
## work out where every part is on every tick that follows, so a runner's client predicting a
## jump over an opening trapdoor sweeps it against the same trapdoor the server does, and a
## client that hears about a press late re-poses the past correctly the next time its
## prediction is corrected, because the tick the press happened on is part of the message.
##
## [b]Three kinds of thing, by what they do to a player:[/b]
##
## - [b]still[/b] (box, ramp, ball, cylinder): a static collider;
## - [b]carriers[/b] (mover, turntable, and every SOLID trap part that moves — a trapdoor, a
##   bridge that rolls over): solid, and whoever stands on one is moved with it by [method
##   carry], the exact displacement between two poses, as in mg-wipeout;
## - [b]killers[/b] (the `kill` pieces, and every LETHAL trap part): NOT solid. They are
##   measured ([method lethal_at]) against the player's capsule every tick. A spike wall that
##   was solid would push somebody out of itself before the test found them inside it, and
##   which way a body is pushed depends on the order two bodies were resolved in.
##
## [b]Moving bodies are STATIC bodies, teleported — never `AnimatableBody3D`.[/b] mg-wipeout's
## finding, unchanged: the physics server applies a kinematic body's new transform at its next
## step, so a client replaying six predicted ticks in one frame swept all six against a
## trapdoor a frame old. A static body's transform, written through `PhysicsServer3D` as well
## as the node ([method _place]), is applied at once.

const CHANNEL := "dr.course"

## The capsule a player is measured as, in metres. Matches [DrPlayer]'s tunables.
const PLAYER_RADIUS := 0.35
const PLAYER_HEIGHT := 1.8
const PLAYER_CROUCHED := 0.9

## How far below a start gate goes when it opens.
const GATE_DROP := 80.0

## How opaque the start gate is drawn. See [method gate_material].
const GATE_ALPHA := 0.35

## What [method lethal_at] answers for the always-on killers: a pit, a pool, a drop.
const KILLED_BY_COURSE := -2

## And for nothing.
const KILLED_BY_NOTHING := -1

## dot-lighting's contact shade, loaded by path (API 4): see [method _add_contact_shade].
const CONTACT_SHADE_SCRIPT := "res://addons/dot_lighting/runtime/dot_contact_shade.gd"

## What a bake of this game's courses means beyond the document (which pieces are in it, its
## settings in tools/lightmap_scenes.gd). Bump it and every committed bake reads as stale.
const BAKE_VERSION := 1

## Where a course's bake is, by id; rebased, so a delivered pack finds its own.
const BAKE_PATH := "res://lightmaps/%s.res"

## dot-lighting's baker and lightmap sheet (API 5), loaded by path like the contact shade: a
## class_name here would fail to parse this whole file under a shell whose dot-lighting is older.
const BAKE_SCRIPT := "res://addons/dot_lighting/bake/dot_light_bake.gd"
const SHEET_SCRIPT := "res://addons/dot_lighting/bake/dot_lightmap_sheet.gd"

## The height of a button's top, above the floor its `at` names.
const BUTTON_HEIGHT := 1.05

## Whether a client looks for a course's bake at all. Off draws every course with the live sun
## and fill alone (and is what the bake scenes are made with).
static var use_bakes: bool = true

## Set by tools/lightmap_scenes.gd: build the bakeable meshes even though no bake exists yet.
static var for_bake_scene: bool = false

## Emitted when the course has been built and posed once.
signal built()

## Whether to draw the sky, the sun and the void. A client sets this; a server need not.
@export var draw_world: bool = false

## The collision layout everything is put on. Set by [DrGame] before [method build].
var physics: DotPhysicsLayout = null

## The normalised document this was built from. See [DrCourseDoc].
var doc: Dictionary = {}

## Ticks a second, for turning a tick into the time every formula is written in.
var tick_rate: int = 64

## Whether the start gate stands. [DrGame] closes it for the countdown.
var gate_closed: bool = false:
	set(value):
		gate_closed = value
		_place_gate()

## One per still or always-moving piece, in document order.
var pieces: Array[Dictionary] = []

## One per trap, in document order: `{spec, node, parts: [{spec, node, moving, carrier}], button}`.
var traps: Array[Dictionary] = []

## trap index -> the tick its button was last pressed on, or -1. THE state of a course; see
## the class note.
var fired: PackedInt32Array = PackedInt32Array()

## Collider instance id -> `[piece index, -1]` or `[trap index, part index]` with a flag in
## the third slot saying which. For the carry.
var _by_collider: Dictionary = {}

## The tick the moving pieces were last posed at, so a second call for the same tick is free.
var _posed_tick: int = -2147483648
var _posed_time: float = -1.0

## The map's toys (dot-props' [DotPropToyBox]): loose ones only on a course (balls,
## tyres, barrels in the start room and the arena), simulated where [member authoritative], posed from snapshots elsewhere,
## under the game's `sv_toys*` [member toy_rules]. Set by the game before it builds.
var toys: DotPropToyBox = null
var authoritative: bool = true
var toy_rules: DotPropToyRules = null
var gravity: float = 20.0

## The LightmapGI laid over this course, or null: drawn with live light alone.
var baked: LightmapGI = null

var _gate: StaticBody3D = null
var _gate_rest: Transform3D = Transform3D.IDENTITY

## The two colours a button's cap can be, shared by every button.
static var _ready_material: StandardMaterial3D = null
static var _spent_material: StandardMaterial3D = null


# --- Building ---------------------------------------------------------------

## Builds everything [param p_doc] describes, replacing whatever was here.
##
## [b]The old pieces are taken out of the tree now and freed at the end of the frame.[/b]
## A round can change course inside the netcode's own tick, and freeing a body there frees
## something [DotNetManager.server_tick] may still be walking.
func build(p_doc: Dictionary) -> DotResult:
	clear()

	var checked := DrCourseDoc.validate(p_doc)

	if not checked.ok:
		return checked

	doc = checked.value
	# The theme's surface skin is the materials' for the length of this build only: they are cached
	# per skin, and nothing built later (a figure, the HUD) should be drawn in a course's photographs.
	DrTextures.skin = str((doc["theme"] as Dictionary).get("surface", ""))

	for index in range((doc["pieces"] as Array).size()):
		_make_piece(index, doc["pieces"][index])

	for index in range((doc["traps"] as Array).size()):
		_make_trap(index, doc["traps"][index])

	fired.resize(traps.size())
	fired.fill(-1)

	_build_gate()
	_build_markers()
	_build_toys()

	if draw_world:
		_build_world()
		_add_contact_shade()

		if use_bakes:
			_attach_bake()

	DrTextures.skin = ""
	pose_at_time(0.0)
	built.emit()

	DotLog.debug(CHANNEL, "built", {
		"id": id(), "pieces": pieces.size(), "traps": traps.size(),
		"digest": DrCourseDoc.digest(doc),
	})
	return DotResult.success(self)


## The toys, on their own layer: a loose one (a ball, a tyre) on `toy`, which the course and its
## traps and the other toys stop and a runner never does (they walk through it and push it,
## `DrGame._advance_toys`): a crusher or a trapdoor sends a ball flying.
func _build_toys() -> void:
	toys = DotPropToyBox.new()
	toys.name = "Toys"
	toys.authoritative = authoritative
	toys.draw = draw_world
	if toy_rules != null:
		toys.rules = toy_rules
	toys.gravity = gravity
	toys.kill_y = kill_height()
	if physics != null:
		toys.loose_layer = physics.layer_mask(&"toy")
		toys.loose_mask = physics.collision_mask(&"toy")
		toys.solid_layer = physics.layer_mask(&"world")
		toys.solid_mask = physics.collision_mask(&"world")
		toys.footprint_layer = physics.layer_mask(&"footprint")
		toys.aim_mask = physics.layer_mask(&"world") | physics.layer_mask(&"toy")
	add_child(toys)
	var built := toys.build(doc.get("toys", []))
	if not built.ok:
		DotLog.warn(CHANNEL, "a map's toys would not build", {"map": String(id()), "why": built.error.message})


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	pieces.clear()
	traps.clear()
	fired = PackedInt32Array()
	_by_collider.clear()
	doc = {}
	baked = null
	toys = null
	_gate = null
	_posed_tick = -2147483648
	_posed_time = -1.0


func id() -> StringName:
	return StringName(str(doc.get("id", "")))


func _make_piece(index: int, spec: Dictionary) -> void:
	var kind := str(spec["kind"])
	var role := _role(str(spec.get("role", "deck")))
	var piece := {"index": index, "kind": kind, "spec": spec, "node": null, "moving": false}

	match kind:
		"box":
			piece["node"] = _static_box(spec["at"], spec["size"], spec["yaw"], 0.0, role, spec)
		"teleport":
			piece["node"] = _static_box(spec["at"], spec["size"], spec["yaw"], 0.0, role, spec) \
				if bool(spec.get("solid", true)) else _trigger_volume(spec)
		"ramp":
			piece["node"] = _static_box(spec["at"], spec["size"], spec["yaw"], float(spec["pitch"]), role, spec)
		"ball":
			piece["node"] = _static_round(spec, role, true)
		"cylinder":
			piece["node"] = _static_round(spec, role, false)
		"mover":
			piece["node"] = _moving_box(spec["size"], role)
			piece["moving"] = true
		"turntable":
			piece["node"] = _moving_disc(float(spec["radius"]), float(spec.get("thickness", 0.6)), role)
			piece["moving"] = true
		"kill":
			piece["node"] = _killer(spec)

	var node: Node3D = piece["node"]

	if node == null:
		return

	node.name = "%s_%d" % [kind, index]
	add_child(node)

	if draw_world and is_bakeable(spec, kind) and _will_bake():
		_make_bakeable(node, spec["size"])

	if not bool(spec.get("visible", true)):
		for child in node.get_children():
			if child is MeshInstance3D:
				(child as MeshInstance3D).visible = false

	var bodies: Array = []
	_collect_bodies(node, bodies)

	for body: CollisionObject3D in bodies:
		_by_collider[body.get_instance_id()] = [index, -1]
		_put_on_world_layer(body)

	pieces.append(piece)


## Whether a piece is drawn into the baked light: still, solid-coloured and a plain box (a
## ramp is a box pitched). Everything that moves, flips lethal or is see-through is lit live
## and left out: a mover, a turntable, every trap part, the gate, a ball or a cylinder, a
## tinted-transparent or invisible piece. A baked shadow under a part that then moves away would
## stay behind on the floor, and a moving part's own faces would carry the light of where it was.
static func is_bakeable(spec: Dictionary, kind: String) -> bool:
	return (kind == "box" or kind == "ramp") and bool(spec.get("visible", true)) \
		and (spec.get("tint", Color.WHITE) as Color).a >= 1.0


## Whether this client can and will lay a bake over this course: the addon is new enough, bakes
## are on and one ships for it (or a bake scene is being made). Otherwise the pieces keep their
## BoxMesh, which is what a workshop or user course always draws.
func _will_bake() -> bool:
	if DotAddonApi.build_level("dot_lighting") < 5 or not ResourceLoader.exists(BAKE_SCRIPT) \
			or not ResourceLoader.exists(SHEET_SCRIPT):
		DotLog.debug(CHANNEL, "this dot-lighting cannot bake; the course is drawn live", {"id": String(id())})
		return false

	if for_bake_scene:
		return true

	return use_bakes and ResourceLoader.exists(DrPaths.rebase(BAKE_PATH % String(id())))


## Swaps a bakeable piece's BoxMesh for the same six faces with a second UV set
## (dot-lighting's `DotLightmapSheet`), in the body's own space and under a name that is the same on every
## build: a bake names its meshes by path from the [LightmapGI]. The world-space triplanar
## material does not read the first UVs, so it draws exactly as the BoxMesh did.
func _make_bakeable(body: Node3D, size: Vector3) -> void:
	for child in body.get_children():
		if not (child is MeshInstance3D):
			continue

		var h := size * 0.5
		var sheet: RefCounted = (load(SHEET_SCRIPT) as GDScript).new()
		var faces := [
			[Vector3.RIGHT, Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, -h.y, h.z)],
			[Vector3.LEFT, Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, -h.y, -h.z)],
			[Vector3.UP, Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z)],
			[Vector3.DOWN, Vector3(-h.x, -h.y, h.z), Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z)],
			[Vector3.BACK, Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, -h.y, h.z)],
			[Vector3.FORWARD, Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, -h.y, -h.z)],
		]

		for face: Array in faces:
			sheet.call(&"face", face[1], face[2], face[3], face[4], face[0])

		var tool := SurfaceTool.new()
		tool.begin(Mesh.PRIMITIVE_TRIANGLES)
		sheet.call(&"commit", tool)
		var mesh := tool.commit()
		mesh.lightmap_size_hint = sheet.get(&"size")
		(child as MeshInstance3D).mesh = mesh
		child.name = "Mesh"
		child.set_meta(&"dr_bakeable", true)
		return


## What this course's bake must have been made from: the still boxes and ramps that are in it,
## the theme (the sky and sun are what the bake lights with, the deck colour what it bounces),
## and the versions of everything that lays them out. The same on the machine that baked and on
## every client, from the document alone. A trap or a mover changing does not touch it.
func light_fingerprint() -> String:
	var pieces_in: Array = []

	for spec: Dictionary in (doc.get("pieces", []) as Array):
		if not is_bakeable(spec, str(spec["kind"])):
			continue

		var tint: Color = spec.get("tint", Color.WHITE)
		pieces_in.append([str(spec["kind"]), str(spec.get("role", "deck")), str(spec["at"]), str(spec["size"]),
			float(spec["yaw"]), float(spec.get("pitch", 0.0)), tint.to_html()])

	var theme: Dictionary = doc.get("theme", {})
	var colours := {}

	for key: String in theme:
		colours[key] = (theme[key] as Color).to_html() if theme[key] is Color else theme[key]

	if DotAddonApi.build_level("dot_lighting") < 5 or not ResourceLoader.exists(BAKE_SCRIPT):
		return ""

	return (load(BAKE_SCRIPT) as GDScript).call(&"fingerprint", {
		"dr": BAKE_VERSION, "pieces": pieces_in, "theme": colours, "light": light_document(theme),
	})


## The course's bake laid over it, if the game ships one made from this document.
func _attach_bake() -> void:
	var path := DrPaths.rebase(BAKE_PATH % String(id()))
	if DotAddonApi.build_level("dot_lighting") < 5 or not ResourceLoader.exists(BAKE_SCRIPT):
		return

	var res: DotResult = (load(BAKE_SCRIPT) as GDScript).call(&"attach", self, path, light_fingerprint())

	if not res.ok:
		return

	baked = res.value
	DotLog.debug(CHANNEL, "the course is drawn with its baked light", {"id": String(id())})


func _collect_bodies(node: Node, into: Array) -> void:
	if node is CollisionObject3D:
		into.append(node)

	for child in node.get_children():
		_collect_bodies(child, into)


func _put_on_world_layer(body: CollisionObject3D) -> void:
	if physics == null:
		return

	var applied := physics.apply_to(body, &"world")

	if not applied.ok:
		DotLog.warn(CHANNEL, "a piece could not be put on its collision layer", {
			"why": applied.error.message,
		})


static func _role(name: String) -> DrTextures.Role:
	match name:
		"pillar":
			return DrTextures.Role.PILLAR
		"cannon":
			return DrTextures.Role.CANNON
		"arena":
			return DrTextures.Role.ARENA
		"hazard":
			return DrTextures.Role.HAZARD
		"safe":
			return DrTextures.Role.SAFE
		_:
			return DrTextures.Role.DECK


static func _yaw_basis(yaw_degrees: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(yaw_degrees))


## The colour the theme gives a role: its deck colour for the ground, white for the rest.
func _theme_tint(role: DrTextures.Role) -> Color:
	if role == DrTextures.Role.DECK:
		return (doc.get("theme", {}) as Dictionary).get("deck", Color.WHITE)

	return Color.WHITE


## A surface's material: its role's, tinted if the document says so (a piece's own `tint`, or
## the theme's deck colour for the ground everything is built of).
func _material(role: DrTextures.Role, moving: bool, spec: Dictionary = {}) -> StandardMaterial3D:
	var tint: Color = spec.get("tint", Color.WHITE)

	if tint == Color.WHITE and role == DrTextures.Role.DECK:
		tint = (doc.get("theme", {}) as Dictionary).get("deck", Color.WHITE)

	return DrTextures.tinted(role, tint, moving)


func _static_box(at: Vector3, size: Vector3, yaw: float, pitch: float, role: DrTextures.Role,
		spec: Dictionary = {}) -> StaticBody3D:
	var body := StaticBody3D.new()
	# Pitch about the piece's own X axis, positive raising its far (-Z) end: a ramp a mapper
	# writes as "pitch 15" climbs away from the start the way the course runs.
	body.transform = Transform3D(_yaw_basis(yaw) * Basis(Vector3.RIGHT, deg_to_rad(pitch)), at)
	_add_box(body, size, _material(role, false, spec), true)
	return body


func _static_round(spec: Dictionary, role: DrTextures.Role, sphere: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])

	var mesh := MeshInstance3D.new()
	var shape := CollisionShape3D.new()

	if sphere:
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = float(spec["radius"])
		sphere_mesh.height = float(spec["radius"]) * 2.0
		mesh.mesh = sphere_mesh

		var sphere_shape := SphereShape3D.new()
		sphere_shape.radius = float(spec["radius"])
		shape.shape = sphere_shape
	else:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = float(spec["radius"])
		cylinder.bottom_radius = float(spec["radius"])
		cylinder.height = float(spec["height"])
		mesh.mesh = cylinder

		var cylinder_shape := CylinderShape3D.new()
		cylinder_shape.radius = float(spec["radius"])
		cylinder_shape.height = float(spec["height"])
		shape.shape = cylinder_shape

	mesh.material_override = _material(role, false, spec)
	body.add_child(mesh)
	body.add_child(shape)
	return body


static func _add_box(parent: Node3D, size: Vector3, material: Material, solid: bool,
		offset: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = offset
	mesh.material_override = material
	parent.add_child(mesh)

	if solid:
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		shape.position = offset
		parent.add_child(shape)

	return mesh


## Puts [param body] at [param at] in the node AND in the physics server, now. See the class
## note: the node alone reaches the physics server a frame late.
static func _place(body: Node3D, at: Transform3D) -> void:
	body.transform = at

	if body is CollisionObject3D and body.is_inside_tree():
		PhysicsServer3D.body_set_state(
			(body as CollisionObject3D).get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
			body.global_transform
		)


func _moving_box(size: Vector3, role: DrTextures.Role) -> StaticBody3D:
	var body := StaticBody3D.new()
	_add_box(body, size, DrTextures.surface(role, true), true)
	return body


func _moving_disc(radius: float, thickness: float, role: DrTextures.Role) -> StaticBody3D:
	var body := StaticBody3D.new()

	var mesh := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = thickness
	cylinder.radial_segments = 48
	mesh.mesh = cylinder
	mesh.material_override = DrTextures.surface(role, true)
	body.add_child(mesh)

	# A bar across the top: a disc of one colour turning reads as still from most angles.
	var bar := MeshInstance3D.new()
	var bar_box := BoxMesh.new()
	bar_box.size = Vector3(radius * 1.9, 0.04, 0.5)
	bar.mesh = bar_box
	bar.position = Vector3(0.0, thickness * 0.5 + 0.02, 0.0)
	bar.material_override = DrTextures.surface(DrTextures.Role.PILLAR, true)
	body.add_child(bar)

	var shape := CollisionShape3D.new()
	var cylinder_shape := CylinderShape3D.new()
	cylinder_shape.radius = radius
	cylinder_shape.height = thickness
	shape.shape = cylinder_shape
	body.add_child(shape)
	return body


## A volume that kills: drawn as what it is, never solid.
func _trigger_volume(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.set_meta(&"dot_no_collision", true)
	root.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])
	return root


func _killer(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	# Measured by `lethal_at`, never collided: a pit's spikes or pool have no shape on purpose.
	root.set_meta(&"dot_no_collision", true)
	root.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])
	_draw_look(root, spec["size"], str(spec.get("look", "spikes")), "up",
		spec.get("tint", Color.WHITE), false)
	return root


## Draws one box-shaped thing as what it looks like. Meshes only; what it does is decided by
## the box, never by the drawing.
func _draw_look(parent: Node3D, size: Vector3, look: String, face: String, tint: Color,
		moving: bool, role: DrTextures.Role = DrTextures.Role.HAZARD) -> void:
	match look:
		"none":
			pass
		"spikes":
			_draw_spikes(parent, size, face, tint, moving)
		"blade":
			var disc := MeshInstance3D.new()
			disc.name = "Blade"
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = maxf(size.x, size.z) * 0.5
			cylinder.bottom_radius = cylinder.top_radius
			cylinder.height = size.y
			cylinder.radial_segments = 40
			disc.mesh = cylinder
			disc.material_override = _metal(tint)
			parent.add_child(disc)

			# Teeth, so a spinning disc reads as spinning.
			for tooth in range(8):
				var spike := MeshInstance3D.new()
				var box := BoxMesh.new()
				box.size = Vector3(cylinder.top_radius * 0.35, size.y * 1.02, cylinder.top_radius * 0.12)
				spike.mesh = box
				var angle := TAU * float(tooth) / 8.0
				spike.position = Vector3(cos(angle), 0.0, sin(angle)) * cylinder.top_radius
				spike.rotation = Vector3(0.0, -angle, 0.0)
				spike.material_override = DrTextures.surface(DrTextures.Role.HAZARD, true)
				disc.add_child(spike)
		"fire":
			var flame := MeshInstance3D.new()
			flame.name = "Flame"
			var box := BoxMesh.new()
			box.size = size
			flame.mesh = box
			flame.material_override = _glow(tint if tint != Color.WHITE else Color(1.0, 0.45, 0.08), 0.62)
			parent.add_child(flame)
		"wind":
			# Streaks along the push, not a solid-looking box: a runner reads a fan from a jump
			# away, and a block of glass reads as a wall.
			var air := MeshInstance3D.new()
			air.name = "Wind"
			var box := BoxMesh.new()
			box.size = size
			air.mesh = box
			air.material_override = _glow(tint if tint != Color.WHITE else Color(0.7, 0.9, 1.0), 0.18, 0.4)
			parent.add_child(air)
		"liquid":
			var pool := MeshInstance3D.new()
			pool.name = "Liquid"
			var box := BoxMesh.new()
			box.size = size
			pool.mesh = box
			pool.material_override = _glow(tint if tint != Color.WHITE else Color(0.25, 0.55, 0.85), 0.78, 0.15)
			parent.add_child(pool)
		_:
			var _box := _add_box(parent, size, DrTextures.tinted(role, tint, moving), false)


## A bed of spikes filling [param size], pointing along [param face].
##
## [b]Cones on a base plate, and the cones are the whole tell.[/b] A trap part a runner must
## not touch has to be readable as one from a jump away, and the shape carries that where a
## colour alone does not; the plate is the hazard red besides.
func _draw_spikes(parent: Node3D, size: Vector3, face: String, tint: Color, moving: bool) -> void:
	# Which way the points go, and the box's extent along it and across it.
	var up := Vector3.UP
	match face:
		"down":
			up = Vector3.DOWN
		"forward":
			up = Vector3.FORWARD
		"back":
			up = Vector3.BACK
		"left":
			up = Vector3.LEFT
		"right":
			up = Vector3.RIGHT

	var along := absf(up.dot(size))
	var across_a := Vector3.RIGHT if absf(up.x) < 0.5 else Vector3.FORWARD
	var across_b := up.cross(across_a).normalized()
	var width_a := absf(across_a.dot(size))
	var width_b := absf(across_b.dot(size))

	# The plate the points stand on: a fifth of the depth, at the back.
	var plate_depth := along * 0.18
	var plate := MeshInstance3D.new()
	var plate_box := BoxMesh.new()
	plate_box.size = (size - up.abs() * (along - plate_depth))
	plate.mesh = plate_box
	plate.position = -up * (along * 0.5 - plate_depth * 0.5)
	# The hazard red, not the walls' colour: the walls are a pale lavender, and a spike wall's
	# plate in the walls' colour was a spike wall that vanished into the wall it slides out of.
	plate.material_override = DrTextures.surface(DrTextures.Role.HAZARD, moving)
	parent.add_child(plate)

	var pitch := clampf(minf(width_a, width_b) / 2.0, 0.35, 0.6)
	var count_a := maxi(int(width_a / pitch), 1)
	var count_b := maxi(int(width_b / pitch), 1)
	var radius := pitch * 0.42
	var height := along - plate_depth
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = radius
	cone.height = height
	cone.radial_segments = 8
	var material := _metal(tint)
	# The arc from up to the face, except straight down, where the arc has no one axis.
	var turn := Basis(Vector3.RIGHT, PI) if up.y < -0.99 else Basis(Quaternion(Vector3.UP, up))

	for a in range(count_a):
		for b in range(count_b):
			var spike := MeshInstance3D.new()
			spike.mesh = cone
			spike.material_override = material
			var offset := across_a * ((float(a) + 0.5) / float(count_a) - 0.5) * width_a \
				+ across_b * ((float(b) + 0.5) / float(count_b) - 0.5) * width_b
			spike.transform = Transform3D(turn, offset + up * (plate_depth * 0.5))
			parent.add_child(spike)

	# Very many points is very many draw calls; a field of fifty is past where they read as
	# separate points anyway.
	if count_a * count_b > 400:
		DotLog.debug(CHANNEL, "a large bed of spikes", {"points": count_a * count_b})


static func _metal(tint: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.78, 0.80, 0.84) * (tint if tint != Color.WHITE else Color(1, 1, 1))
	material.metallic = 0.7
	material.roughness = 0.35
	return material


## Something drawn as light rather than surface: fire, a pool.
##
## [b]Translucent ON PURPOSE, and it is the only material here that is.[/b] Writing alpha
## puts a surface in the transparent pass, where it is sorted per surface rather than per
## pixel (docs/gdscript-hazards.md). For a pool and a sheet of fire that is the look; for a
## floor it would be a floor drawn through itself.
static func _glow(colour: Color, alpha: float, emission: float = 0.9) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(colour.r, colour.g, colour.b, alpha)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.emission_enabled = emission > 0.0
	material.emission = colour
	material.emission_energy_multiplier = emission
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


# --- Traps ------------------------------------------------------------------

func _make_trap(index: int, spec: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Trap_%s" % str(spec["id"])
	add_child(root)

	var parts: Array = []

	for part_index in range((spec["parts"] as Array).size()):
		var part_spec: Dictionary = spec["parts"][part_index]
		var moving := (part_spec["move"] as Vector3) != Vector3.ZERO or part_spec.has("turn") \
			or not is_zero_approx(float(part_spec["spin"]))
		var role := _role(str(part_spec["role"]))
		var node: Node3D

		if bool(part_spec["solid"]):
			var body := StaticBody3D.new()
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = part_spec["size"]
			shape.shape = box
			body.add_child(shape)
			node = body
		else:
			node = Node3D.new()
			# A part that is not solid is drawn only: a lethal one is measured (`lethal_at`),
			# never collided, so a drawing with no shape is its design (dot-core DotCollisionAudit).
			node.set_meta(&"dot_no_collision", true)

		node.name = "Part_%d" % part_index
		node.transform = _part_rest(part_spec)
		_draw_look(node, part_spec["size"], str(part_spec["look"]), str(part_spec["face"]),
			part_spec.get("tint", _theme_tint(role)), moving, role)
		root.add_child(node)

		if node is CollisionObject3D:
			_by_collider[node.get_instance_id()] = [index, part_index, true]
			_put_on_world_layer(node as CollisionObject3D)

		parts.append({
			"spec": part_spec,
			"node": node,
			"moving": moving,
			# A lethal part that does not move is a hazard that is OFF until the trap runs —
			# fire, a laser — and ON while it is out. One that moves is lethal wherever it is,
			# because where it is IS whether it is out: spikes at rest are under the floor.
			"switched": (bool(part_spec["lethal"]) or (part_spec["push"] as Vector3) != Vector3.ZERO) \
				and not moving,
		})

	var button := _make_button(spec["button"])
	root.add_child(button)

	traps.append({"spec": spec, "node": root, "parts": parts, "button": button})


## A post with a cap on it, where the activator presses. Not solid: it is in a corridor
## somebody has to walk along, and a post a player catches on is a post that ends a round.
func _make_button(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Button"
	# Not solid, as the note above says: a post a player catches on ends a round.
	root.set_meta(&"dot_no_collision", true)
	root.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])

	var post := MeshInstance3D.new()
	var post_mesh := CylinderMesh.new()
	post_mesh.top_radius = 0.12
	post_mesh.bottom_radius = 0.16
	post_mesh.height = BUTTON_HEIGHT - 0.08
	post.mesh = post_mesh
	post.position = Vector3(0.0, post_mesh.height * 0.5, 0.0)
	post.material_override = DrTextures.surface(DrTextures.Role.PILLAR)
	root.add_child(post)

	var cap := MeshInstance3D.new()
	cap.name = "Cap"
	var cap_mesh := CylinderMesh.new()
	cap_mesh.top_radius = 0.2
	cap_mesh.bottom_radius = 0.22
	cap_mesh.height = 0.12
	cap.mesh = cap_mesh
	cap.position = Vector3(0.0, BUTTON_HEIGHT - 0.04, 0.0)
	cap.material_override = _button_material(true)
	root.add_child(cap)
	return root


static func _button_material(ready: bool) -> StandardMaterial3D:
	if _ready_material == null:
		_ready_material = StandardMaterial3D.new()
		_ready_material.albedo_color = Color(0.25, 0.85, 0.35)
		_ready_material.emission_enabled = true
		_ready_material.emission = Color(0.2, 0.9, 0.3)
		_ready_material.emission_energy_multiplier = 0.8

		_spent_material = StandardMaterial3D.new()
		_spent_material.albedo_color = Color(0.75, 0.18, 0.15)

	return _ready_material if ready else _spent_material


## Where a part rests: its document transform, before any trap has moved it.
static func _part_rest(part: Dictionary) -> Transform3D:
	var basis := _yaw_basis(float(part["yaw"])) * Basis(Vector3.RIGHT, deg_to_rad(float(part["pitch"])))
	return Transform3D(basis, part["at"])


## How far out a trap is, 0 at rest and 1 at full, [param seconds] after its button was
## pressed. Negative seconds is "not pressed".
##
## [b]Eased at both ends, and the hold is the part a runner uses.[/b] A trapdoor that opened
## linearly would drop somebody at the speed it was moving at the instant it started, which
## is nothing; one that eases out reads as a door swinging.
static func extension(timing: Dictionary, seconds: float) -> float:
	if seconds < 0.0:
		return 0.0

	var t := seconds - float(timing["delay"])

	if t <= 0.0:
		return 0.0

	var out := float(timing["out"])

	if t < out:
		return smoothstep(0.0, 1.0, t / maxf(out, 0.0001))

	t -= out
	var hold := float(timing["hold"])

	if hold < 0.0 or t < hold:
		return 1.0

	t -= hold
	var back := float(timing["back"])

	if t < back:
		return 1.0 - smoothstep(0.0, 1.0, t / maxf(back, 0.0001))

	return 0.0


## How long a trap is busy from the press, in seconds: until its parts are home again. INF for
## one that stays out.
static func duration(timing: Dictionary) -> float:
	if float(timing["hold"]) < 0.0:
		return INF

	return float(timing["delay"]) + float(timing["out"]) + float(timing["hold"]) + float(timing["back"])


## Where part [param part] is at extension [param e], [param running] seconds into the trap's
## run. The one formula, used for drawing, colliding, carrying and killing alike.
static func part_transform(part: Dictionary, e: float, running: float) -> Transform3D:
	var at := _part_rest(part)

	if not is_zero_approx(float(part["spin"])) and running > 0.0:
		at.basis = at.basis * Basis(Vector3.UP, deg_to_rad(float(part["spin"]) * running))

	if part.has("turn"):
		var turn: Dictionary = part["turn"]
		var axis := Vector3.RIGHT

		match str(turn["axis"]):
			"y":
				axis = Vector3.UP
			"z":
				axis = Vector3.BACK

		var pivot: Vector3 = turn["pivot"]
		var rotation := Basis(axis, deg_to_rad(float(turn["degrees"]) * e))
		at = Transform3D(rotation, pivot - rotation * pivot) * at

	at.origin += (part["move"] as Vector3) * e
	return at


## Seconds since trap [param index] was pressed, at [param seconds] into the round, or -1.
func _since(index: int, seconds: float) -> float:
	if index < 0 or index >= fired.size() or fired[index] < 0:
		return -1.0

	return seconds - float(fired[index]) / float(maxi(tick_rate, 1))


## The extension of trap [param index] at [param seconds].
func trap_extension(index: int, seconds: float) -> float:
	return extension((traps[index]["spec"] as Dictionary)["timing"], _since(index, seconds))


## Seconds a trap's parts have been running, for a blade's spin: from the end of the delay to
## the moment the trap is home, and frozen after that.
func _running(index: int, seconds: float) -> float:
	var since := _since(index, seconds)

	if since < 0.0:
		return 0.0

	var timing: Dictionary = (traps[index]["spec"] as Dictionary)["timing"]
	return clampf(since - float(timing["delay"]), 0.0, duration(timing) - float(timing["delay"]))


## Records a press, and re-poses on the next ask. What the server does when a button is
## pressed and what a client does when it is told one was.
func set_fired(index: int, tick: int) -> void:
	if index < 0 or index >= fired.size():
		return

	fired[index] = tick
	_posed_tick = -2147483648


## Every trap home, for the top of a round.
func reset_traps() -> void:
	fired.fill(-1)
	_posed_tick = -2147483648


## Whether trap [param index] can be pressed on [param tick].
##
## [b]Once a round unless the document gives it a cooldown[/b], and never while it is still
## running: a trapdoor pressed again while it is open would restart a timeline the runners
## are already timing their crossing against.
func trap_ready(index: int, tick: int) -> bool:
	if index < 0 or index >= fired.size():
		return false

	if fired[index] < 0:
		return true

	var spec: Dictionary = traps[index]["spec"]
	var cooldown := float(spec["cooldown"])

	if cooldown <= 0.0:
		return false

	var since := float(tick - fired[index]) / float(maxi(tick_rate, 1))
	return since >= maxf(cooldown, duration(spec["timing"]))


## Whether trap [param index] is moving or out on [param tick].
func trap_running(index: int, tick: int) -> bool:
	if index < 0 or index >= fired.size() or fired[index] < 0:
		return false

	var since := float(tick - fired[index]) / float(maxi(tick_rate, 1))
	return since < duration((traps[index]["spec"] as Dictionary)["timing"])


func trap_count() -> int:
	return traps.size()


func trap_name(index: int) -> String:
	return str((traps[index]["spec"] as Dictionary)["name"]) if index >= 0 and index < traps.size() else ""


func trap_index(trap_id: String) -> int:
	for index in range(traps.size()):
		if str((traps[index]["spec"] as Dictionary)["id"]) == trap_id:
			return index

	return -1


## Where trap [param index]'s button is pressed from: the top of its post.
func button_point(index: int) -> Vector3:
	var button: Dictionary = (traps[index]["spec"] as Dictionary)["button"]
	return (button["at"] as Vector3) + Vector3(0.0, BUTTON_HEIGHT, 0.0)


## Which button somebody at [param eyes] looking along [param aim] would press: the nearest
## within [param reach] and inside [param cone], or -1.
##
## [b]Whichever is nearest, ready or not.[/b] Pressing a spent button is a press that does
## nothing and says so; skipping it for a ready one behind it would fire a trap the activator
## was not looking at.
func button_for(eyes: Vector3, aim: Vector3, reach: float, cone: float) -> int:
	var best := -1
	var best_distance := INF

	for index in range(traps.size()):
		var to := button_point(index) - eyes
		var distance := to.length()

		if distance > reach or distance >= best_distance:
			continue

		if distance > 0.3 and aim.normalized().dot(to / distance) < cone:
			continue

		best = index
		best_distance = distance

	return best


## The box a trap reaches: where somebody has to be for it to matter. The document's `zone`,
## or every part's box at rest and at full extension, grown by a metre (and two upward, so
## somebody STANDING on a trapdoor is inside its zone). What a stand-in activator watches.
func trap_zone(index: int) -> AABB:
	var spec: Dictionary = traps[index]["spec"]

	if spec.has("zone"):
		var zone: Dictionary = spec["zone"]
		var size: Vector3 = zone["size"]
		return AABB((zone["at"] as Vector3) - size * 0.5, size)

	var box := AABB()
	var first := true

	for part: Dictionary in spec["parts"]:
		for e in [0.0, 0.5, 1.0]:
			var frame := part_transform(part, e, 0.0)
			var half := (part["size"] as Vector3) * 0.5

			for corner in range(8):
				var local := Vector3(
					half.x if corner & 1 else -half.x,
					half.y if corner & 2 else -half.y,
					half.z if corner & 4 else -half.z
				)
				var point := frame * local

				if first:
					box = AABB(point, Vector3.ZERO)
					first = false
				else:
					box = box.expand(point)

	return AABB(box.position - Vector3(1.0, 1.0, 1.0), box.size + Vector3(2.0, 3.0, 2.0))


# --- The start, the finish, the world -----------------------------------------

## The gate across the front of the runners' start, which the countdown holds closed.
func _build_gate() -> void:
	var start: Dictionary = doc["start"]
	var at: Vector3 = start["at"]
	var size: Vector3 = start["size"]
	var basis := _yaw_basis(float(start["yaw"]))

	# Across the front edge, which is -Z in the area's own frame: yaw 0 faces -Z, and the
	# course runs the way the runners are facing.
	_gate = StaticBody3D.new()
	_gate.name = "Gate"
	_gate_rest = Transform3D(basis, at + basis * Vector3(0.0, size.y * 0.5, -size.z * 0.5 - 0.2))
	_add_box(_gate, Vector3(size.x + 0.4, size.y, 0.3), gate_material(), true)
	add_child(_gate)
	_put_on_world_layer(_gate)
	_place_gate()


## The gate's surface: the moving-part tile, see-through.
##
## [b]See-through because a runner spends the whole warmup and countdown facing it[/b], from
## the front row 1.4 m away. Opaque, it filled the screen: every frame of a freshly joined
## player was an orange wall, which read as a spawn facing the wrong way when the spawn faced
## the course exactly as it should. Through it the runner sees what they are about to run.
## Still the moving-part colour (it drops away when the round starts), and still solid.
static func gate_material() -> StandardMaterial3D:
	var material := DrTextures.surface(DrTextures.Role.CANNON).duplicate() as StandardMaterial3D
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color.a = GATE_ALPHA
	return material


func _place_gate() -> void:
	if _gate == null:
		return

	var at := _gate_rest

	if not gate_closed:
		at.origin -= Vector3(0.0, GATE_DROP, 0.0)

	_place(_gate, at)


## An arch over the finish. Meshes only: what counts is the volume ([method in_finish]).
func _build_markers() -> void:
	var finish: Dictionary = doc["finish"]
	var basis := _yaw_basis(float(finish["yaw"]))
	var size: Vector3 = finish["size"]
	var arch := Node3D.new()
	arch.name = "Finish"
	arch.transform = Transform3D(basis, finish["at"])
	add_child(arch)

	var height := maxf(size.y, 2.5)

	for side in [-1.0, 1.0]:
		var _post := _add_box(arch, Vector3(0.4, height, 0.4), DrTextures.surface(DrTextures.Role.PILLAR), false,
			Vector3(side * size.x * 0.5, height * 0.5, 0.0))

	var _beam := _add_box(arch, Vector3(size.x + 0.4, 0.6, 0.4), DrTextures.surface(DrTextures.Role.SAFE), false,
		Vector3(0.0, height, 0.0))


## The sky, the sun, the fog and the void. Client side.
##
## [b]The light is a dot-lighting document made from the course's theme[/b]
## ([method light_document]), so the family's look (game-arena's built-in maps: a warm sun
## with soft shadows, a pale cool fill, filmic tone map, glow) and each course's own sky,
## horizon, sun colour and void are one thing rather than two that can disagree.
## dot-lighting's contact shade (API 4) where the course's still boxes meet: a wall on a deck, a
## pillar on the floor, the walkway's step down. The Compatibility renderer the client draws has
## no ambient occlusion, and every wall stood on its deck with no shade at its foot. Only the
## still, visible, opaque, unpitched `box` pieces: a mover, a turntable and every trap part move
## (or flip lethal), and the shade is one mesh built here, so it would stay where they were; a
## ramp is tilted, which the helper's creases do not follow; the gate is see-through and drops.
## By path, behind the level, so a shell older than the helper draws the course without it.
func _add_contact_shade() -> void:
	if DotAddonApi.build_level("dot_lighting") < 4 or not ResourceLoader.exists(CONTACT_SHADE_SCRIPT):
		return
	var boxes: Array = []
	for piece: Dictionary in pieces:
		var spec: Dictionary = piece["spec"]
		if str(piece["kind"]) != "box" or bool(piece["moving"]) or not bool(spec.get("visible", true)):
			continue
		if (spec.get("tint", Color.WHITE) as Color).a < 1.0:
			continue
		boxes.append({"transform": (piece["node"] as Node3D).transform, "size": spec["size"]})
	if boxes.is_empty():
		return
	var shade: Variant = (load(CONTACT_SHADE_SCRIPT) as GDScript).call(&"node", boxes)
	if shade is MeshInstance3D and (shade as MeshInstance3D).mesh != null:
		(shade as Node).name = "ContactShade"
		add_child(shade)
	elif shade is Node:
		(shade as Node).free()


func _build_world() -> void:
	var theme: Dictionary = doc.get("theme", {})

	var lighting := Node3D.new()
	lighting.name = "Lighting"
	add_child(lighting)
	var sun := DotLightRig.apply(lighting, DotLightDocument.from_dictionary(light_document(theme)), light_profile())
	if sun != null:
		sun.shadow_blur = 1.5

	for node in lighting.get_children():
		if node is WorldEnvironment and (node as WorldEnvironment).environment.sky != null:
			var material := (node as WorldEnvironment).environment.sky.sky_material as ProceduralSkyMaterial
			if material != null:
				# The theme's sky at the zenith (the rig draws it in the ambient colour), and
				# the void's colour under the horizon, which is what a falling runner sees.
				material.sky_top_color = theme.get("sky", Color(0.48, 0.60, 0.74))
				material.ground_bottom_color = theme.get("void", Color(0.10, 0.12, 0.16))

	# The floor of the drop: what everybody who falls sees coming. Drawn only; the fall is a
	# height comparison in [DrGame], because a trigger volume can be stepped over between two
	# ticks by something falling fast enough.
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.name = "Void"
	# Below the kill height, where whoever falls is already dead: nobody stands on it.
	floor_mesh.set_meta(&"dot_no_collision", true)
	var plane := PlaneMesh.new()
	plane.size = Vector2(1600.0, 1600.0)
	floor_mesh.mesh = plane
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = theme.get("void", Color(0.10, 0.12, 0.16))
	floor_material.roughness = 1.0
	floor_mesh.material_override = floor_material
	floor_mesh.position = Vector3(0.0, kill_height() - 2.0, 0.0)
	add_child(floor_mesh)


## The dot-lighting document a course's theme describes.
##
## The angles are dot-lighting's source convention (a negative pitch is a sun in the sky),
## high so a corridor wall does not put the floor in shade, and behind the start, so the
## faces a runner runs toward (a trap's front, the gate) are the lit ones. The brightness is
## divided by the profile's reference and square-rooted. The ambient is the light in the
## shade, a pale cool grey whatever the theme: a saturated fill turns every shaded face into
## the theme's colour and a red hazard in shade into brown. The fog is the theme's horizon
## from 120 m out (source units, metres / 0.01905), so no trap a runner must read is hidden
## in it; the theme's `fog` density was the old exponential fog's and is not used.
static func light_document(theme: Dictionary) -> Dictionary:
	var sun: Color = theme.get("sun", Color(1.0, 0.97, 0.92))
	var horizon: Color = theme.get("horizon", Color(0.80, 0.85, 0.90))
	return {
		"sun": {
			"pitch_src": -54.0,
			"yaw_src": 145.0,
			"colour": [sun.r, sun.g, sun.b],
			"brightness": 380.0,
			"spread_degrees": 1.0,
			"ambient_colour": [0.74, 0.78, 0.92],
		},
		"fog": {
			"enabled": true,
			"colour": [horizon.r, horizon.g, horizon.b],
			"start": 6300.0,
			"end": 40000.0,
			"max_density": 0.25,
		},
	}


## What this machine draws of a course's light: dot-lighting's `painted()`.
##
## [b]Shadows stay on in the browser[/b], unlike dot-lighting's `web()`: a course is a few
## hundred boxes, and a trap's shadow on the floor is how a runner sees where it is.
## `painted()` is the family's profile for a world of flat colours, matched to the renderer
## (the Compatibility renderer this game and the client shell use clips a sunlit pastel to
## white at Forward+'s numbers, and the grid, which is how far a jump is, goes with it). Over
## the hand-set numbers it replaced (the sun divided by 700, a fill of 0.62) it lowers the
## exposure, grades, and trades some ambient for a shadowless fill, so a corridor's two
## shaded walls and a trap's shaded faces are different shades rather than one pastel.
static func light_profile() -> DotLightProfile:
	var p := DotLightProfile.painted()
	p.sun_shadows = true
	return p


# --- Where everything is ------------------------------------------------------

## Poses every moving thing at [param tick]. Idempotent per tick, until a press changes it.
func pose_at(tick: int) -> void:
	if tick == _posed_tick:
		return

	pose_at_time(float(tick) / float(maxi(tick_rate, 1)))
	_posed_tick = tick


## Poses every moving thing at [param seconds]. What a client draws between two ticks.
##
## [b]Forgets which tick it was posed at.[/b] A frame posed between ticks N and N+1 has moved
## every collider off tick N, so the next [method pose_at] for N must not take the shortcut.
func pose_at_time(seconds: float) -> void:
	_posed_time = seconds
	_posed_tick = -2147483648

	for piece in pieces:
		if bool(piece["moving"]):
			_place(piece["node"], transform_of(piece, seconds))

	for index in range(traps.size()):
		var trap: Dictionary = traps[index]
		var e := trap_extension(index, seconds)
		var running := _running(index, seconds)

		for part: Dictionary in trap["parts"]:
			var node: Node3D = part["node"]

			if not is_instance_valid(node):
				continue

			if bool(part["moving"]):
				_place(node, part_transform(part["spec"], e, running))

			# A hazard that switches on is drawn only while it is on, so what a runner sees is
			# what kills: a sheet of fire that was always drawn would be a sheet of fire they
			# learn to walk through.
			if bool(part["switched"]):
				node.visible = e >= 0.5

		_draw_tell(index, seconds)

		var cap := (trap["button"] as Node3D).get_node_or_null(^"Cap") as MeshInstance3D

		if cap != null:
			cap.material_override = _button_material(
				trap_ready(index, int(roundf(seconds * float(maxi(tick_rate, 1)))))
			)


static var _tell_overlay: StandardMaterial3D = null


## The tell: from the press until the parts move, every part of the trap flashes red, as an
## overlay on whatever it is drawn in. Drawing only, never the parts' poses: a trapdoor that
## shook would carry whoever stood on it, and a runner reading the tell must not be moved by it.
func _draw_tell(index: int, seconds: float) -> void:
	var trap: Dictionary = traps[index]
	var timing: Dictionary = (trap["spec"] as Dictionary)["timing"]
	var tell := float(timing.get("tell", 0.0))

	if tell <= 0.0:
		return

	var since := _since(index, seconds)
	var telling := since >= 0.0 and since < float(timing["delay"])

	if _tell_overlay == null:
		_tell_overlay = StandardMaterial3D.new()
		_tell_overlay.albedo_color = Color(1.0, 0.1, 0.05, 0.55)
		_tell_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_tell_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	# Flashing, not steady: on for a tenth, off for a tenth.
	var lit := telling and int(since * 10.0) % 2 == 0

	if not trap.has("meshes"):
		var found: Array = []

		for part: Dictionary in trap["parts"]:
			if is_instance_valid(part["node"]):
				found.append_array((part["node"] as Node).find_children("*", "GeometryInstance3D", true, false))
				if part["node"] is GeometryInstance3D:
					found.append(part["node"])

		trap["meshes"] = found

	for mesh: Variant in trap["meshes"]:
		if is_instance_valid(mesh):
			(mesh as GeometryInstance3D).material_overlay = _tell_overlay if lit else null


## Whether trap [param index] is in its tell at [param seconds]: pressed, not yet moving.
func is_telling(index: int, seconds: float) -> bool:
	var timing: Dictionary = (traps[index]["spec"] as Dictionary)["timing"]
	var since := _since(index, seconds)
	return float(timing.get("tell", 0.0)) > 0.0 and since >= 0.0 and since < float(timing["delay"])


## Where an always-moving carrier is at [param t], as a world transform.
func transform_of(piece: Dictionary, t: float) -> Transform3D:
	var spec: Dictionary = piece["spec"]
	var yaw := _yaw_basis(float(spec.get("yaw", 0.0)))

	match str(piece["kind"]):
		"mover":
			var from: Vector3 = spec["from"]
			var to: Vector3 = spec["to"]
			var cycle := t / float(spec["period"]) + float(spec.get("phase", 0.0))
			return Transform3D(yaw, from.lerp(to, 0.5 - 0.5 * cos(TAU * cycle)))
		"turntable":
			var angle := deg_to_rad(float(spec.get("phase", 0.0)) + float(spec["speed"]) * t)
			return Transform3D(yaw * Basis(Vector3.UP, angle), spec["at"])
		_:
			return (piece["node"] as Node3D).transform


# --- What a player's movement asks ----------------------------------------------

## How far whatever [param ground_id] is moves a point at [param at] between [param tick]
## and the next one. Zero for anything that does not move.
##
## [b]The exact displacement, not a velocity times a step.[/b] mg-wipeout's: a point on a
## turning thing moves along an arc, and a velocity taken at the start of the tick moves it
## along the tangent, which spirals a player standing still off a turntable — or, here, off a
## bridge that rolls over, a little early.
func carry(ground_id: int, at: Vector3, tick: int) -> Vector3:
	var found: Variant = _by_collider.get(ground_id)

	if found == null:
		return Vector3.ZERO

	var where: Array = found
	var dt := 1.0 / float(maxi(tick_rate, 1))
	var t := float(tick) * dt

	if where.size() > 2:
		var trap_index := int(where[0])
		var trap: Dictionary = traps[trap_index]
		var part: Dictionary = trap["parts"][int(where[1])]

		if not bool(part["moving"]):
			return Vector3.ZERO

		var now := part_transform(part["spec"], trap_extension(trap_index, t), _running(trap_index, t))
		var next := part_transform(part["spec"], trap_extension(trap_index, t + dt), _running(trap_index, t + dt))
		return (next * now.affine_inverse()) * at - at

	var piece: Dictionary = pieces[int(where[0])]

	if not bool(piece["moving"]):
		return Vector3.ZERO

	var before := transform_of(piece, t)
	var after := transform_of(piece, t + dt)
	return (after * before.affine_inverse()) * at - at


## How far the wind moves somebody whose feet are at [param feet] during [param tick]: the sum of
## every running push zone their capsule's middle is in, times one tick.
##
## [b]A displacement, like the carry.[/b] It is a pure function of the tick, the press and where
## the player stands, added to the state in `_after_tick`, so the server and a predicting client
## (and its replay) move the player identically. Nothing is collided and no body is pushed:
## physics order would differ between machines.
func push_at(feet: Vector3, crouched: bool, tick: int) -> Vector3:
	var dt := 1.0 / float(maxi(tick_rate, 1))
	var t := float(tick) * dt
	var middle := feet + Vector3(0.0, (PLAYER_CROUCHED if crouched else PLAYER_HEIGHT) * 0.5, 0.0)
	var total := Vector3.ZERO

	for index in range(traps.size()):
		if fired[index] < 0:
			continue

		var e := trap_extension(index, t)

		if e < 0.5:
			continue

		var running := _running(index, t)

		for part: Dictionary in traps[index]["parts"]:
			var spec: Dictionary = part["spec"]
			var push: Vector3 = spec["push"]

			if push == Vector3.ZERO:
				continue

			var frame := part_transform(spec, e, running)
			var local := frame.affine_inverse() * middle
			var half: Vector3 = (spec["size"] as Vector3) * 0.5

			if absf(local.x) <= half.x and absf(local.y) <= half.y and absf(local.z) <= half.z:
				total += push * dt

	return total


## What kills somebody standing at [param feet] on [param tick]: a trap's index,
## [constant KILLED_BY_COURSE] for a pit, a pool or a drop, or [constant KILLED_BY_NOTHING].
##
## [b]A measurement, not a contact.[/b] See the class note: nothing that kills is solid, and the
## question is asked of the capsule's own axis against each box, the same arithmetic on both
## ends.
func lethal_at(feet: Vector3, crouched: bool, tick: int) -> int:
	var t := float(tick) / float(maxi(tick_rate, 1))
	var top := feet + Vector3(0.0, (PLAYER_CROUCHED if crouched else PLAYER_HEIGHT) - PLAYER_RADIUS, 0.0)
	var bottom := feet + Vector3(0.0, PLAYER_RADIUS, 0.0)

	for index in range(traps.size()):
		# A trap nobody has pressed is a trap at rest, and nothing at rest kills — spikes are
		# under the floor, fire is off. Skipped rather than measured, which is most of a tick.
		if fired[index] < 0:
			continue

		var e := trap_extension(index, t)

		if e <= 0.0:
			continue

		var running := _running(index, t)

		for part: Dictionary in traps[index]["parts"]:
			var spec: Dictionary = part["spec"]

			if not bool(spec["lethal"]):
				continue

			if bool(part["switched"]) and e < 0.5:
				continue

			if _capsule_in_box(bottom, top, part_transform(spec, e, running), spec["size"]):
				return index

	for piece in pieces:
		if str(piece["kind"]) != "kill":
			continue

		var spec: Dictionary = piece["spec"]

		if _capsule_in_box(bottom, top, Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"]), spec["size"]):
			return KILLED_BY_COURSE

	return KILLED_BY_NOTHING


## Where a teleport under [param feet] sends whoever is in it, as `[position, heading, keep]`,
## or an empty array when they are in none. A solid pad takes feet within its footprint and
## between a little under its top and a metre over it (a runner jumping across its corner is
## still sent, one a long way under it, falling past, is not); a trigger volume (`solid` false)
## takes feet inside its box. `keep` says whether their velocity goes with them. Pure in the
## position: the tick calls it on the server and on a predicting client alike. The same piece as
## mg-wipeout's; dot-map is where a shared one belongs once it is free to take it.
## [param runner] picks the pads meant for that side.
func teleport_at(feet: Vector3, runner: bool = true) -> Array:
	for piece in pieces:
		if str(piece["kind"]) != "teleport":
			continue

		var spec: Dictionary = piece["spec"]
		var side := str(spec.get("for", ""))

		if (side == "runners" and not runner) or (side == "activators" and runner):
			continue

		if DrCourseDoc.pad_contains(spec, feet):
			return [spec["to"], float(spec.get("heading", 0.0)), bool(spec.get("keep", false))]

	return []


## Whether a capsule from [param bottom] to [param top] (both sphere centres) touches a box.
static func _capsule_in_box(bottom: Vector3, top: Vector3, frame: Transform3D, size: Vector3) -> bool:
	var inverse := frame.affine_inverse()
	var half := size * 0.5

	# Five samples up the axis: a capsule's distance to a box is not a closed form worth the
	# trouble, and at a 1.1 m axis five samples are 27 cm apart — under the capsule's own radius,
	# so nothing thinner than a radius passes between two of them.
	for step in range(5):
		var local := inverse * bottom.lerp(top, float(step) / 4.0)
		var clamped := Vector3(
			clampf(local.x, -half.x, half.x),
			clampf(local.y, -half.y, half.y),
			clampf(local.z, -half.z, half.z)
		)

		if local.distance_to(clamped) <= PLAYER_RADIUS:
			return true

	return false


# --- The course's own facts -----------------------------------------------------

func kill_height() -> float:
	return float(doc.get("kill_height", -12.0))


## Whether somebody standing at [param feet] is across the finish.
func in_finish(feet: Vector3) -> bool:
	if doc.is_empty():
		return false

	var finish: Dictionary = doc["finish"]
	return _inside(feet + Vector3(0.0, 0.9, 0.0), finish["at"], finish["size"], float(finish["yaw"]))


## Whether [param point] is inside an area whose FLOOR-centre is [param at].
static func _inside(point: Vector3, at: Vector3, size: Vector3, yaw: float) -> bool:
	var local := _yaw_basis(yaw).inverse() * (point - at)
	return absf(local.x) <= size.x * 0.5 and local.y >= -0.5 and local.y <= size.y \
		and absf(local.z) <= size.z * 0.5


## Where seat [param seat] of [param of] stands in an area. Returns `[position, yaw]`.
##
## Rows across the area from the front, a metre and a half apart, so twenty-four runners are
## four rows of six on a nine-metre start and nobody is placed inside anybody. Full rows when
## [param of] is large, so a joiner's seat does not move the seats of the people already there.
static func spot_in(area: Dictionary, seat: int, of: int) -> Array:
	var size: Vector3 = area["size"]
	var basis := _yaw_basis(float(area["yaw"]))
	var per_row := maxi(int((size.x - 1.0) / 1.5), 1)
	var rows := maxi(int((size.z - 1.0) / 1.5), 1)
	var row := (seat / per_row) % rows
	var column := seat % per_row
	var in_row := mini(per_row, of - (seat / per_row) * per_row)
	var x := (float(column) - float(maxi(in_row, 1) - 1) * 0.5) * 1.5
	# A row behind the last one comes back to the front, a little to one side: a full server
	# in a small area is people standing close rather than people standing outside it.
	if seat / per_row >= rows:
		x += 0.6
	var z := -size.z * 0.5 + 1.2 + float(row) * 1.5
	z = minf(z, size.z * 0.5 - 0.6)
	return [(area["at"] as Vector3) + basis * Vector3(x, 0.2, z), float(area["yaw"])]


func start_spot(seat: int, of: int) -> Array:
	return spot_in(doc["start"], seat, of) if not doc.is_empty() else [Vector3.ZERO, 0.0]


func activator_spot(seat: int, of: int) -> Array:
	return spot_in(doc["activators"], seat, of) if not doc.is_empty() else [Vector3.ZERO, 0.0]


## Where somebody arrives in the end arena: [param runners] for a runner who crossed the line,
## otherwise an activator who was called.
func end_spot(runners: bool, seat: int) -> Array:
	if doc.is_empty():
		return [Vector3.ZERO, 0.0]

	return spot_in((doc["end"] as Dictionary)["runners" if runners else "activators"], seat, 1000)


## The route a stand-in runner follows, as the document gives it.
func route() -> Array:
	return doc.get("route", [])


## The walkway a stand-in activator follows, as the document gives it (empty: straight at the button).
func walkway() -> Array:
	return doc.get("walkway", [])


## The walkway point where trap [param index]'s button is pressed from, or -1.
func walkway_stop(index: int) -> int:
	var trap_id := str((traps[index]["spec"] as Dictionary)["id"])
	var points := walkway()

	for i in range(points.size()):
		if str((points[i] as Dictionary)["button"]) == trap_id:
			return i

	return -1


## How far along the route [param point] is: the index of the nearest route point, or -1 for a
## course without a route. Nearest by flat distance with height counted double, so a ledge
## above a route point is not mistaken for the floor beside it.
func route_progress(point: Vector3) -> int:
	var points := route()
	var best := -1
	var best_distance := INF

	for i in range(points.size()):
		var at: Vector3 = (points[i] as Dictionary)["at"]
		var distance := Vector2(at.x - point.x, at.z - point.z).length() + 2.0 * absf(at.y - point.y)

		if distance < best_distance:
			best_distance = distance
			best = i

	return best


## Roughly where the middle of everything is, and how far it reaches. For an overview camera.
func bounds() -> AABB:
	var box := AABB()
	var first := true

	for piece in pieces:
		var spec: Dictionary = piece["spec"]
		var at: Vector3 = spec.get("at", spec.get("from", Vector3.ZERO))

		if first:
			box = AABB(at, Vector3.ZERO)
			first = false
		else:
			box = box.expand(at)

	return box


func describe() -> Dictionary:
	var used := 0

	for tick in fired:
		if tick >= 0:
			used += 1

	return {
		"id": String(id()),
		"name": str(doc.get("name", "-")),
		"pieces": pieces.size(),
		"traps": traps.size(),
		"pressed": used,
		"gate": "closed" if gate_closed else "open",
		"posed": "%.2f s" % _posed_time,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["course"])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-12s %s" % [key, facts[key]])

	return lines
