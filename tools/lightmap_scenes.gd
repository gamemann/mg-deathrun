extends Node

const DrCatalogue := preload("../game/dr_catalogue.gd")
const DrCourse := preload("../game/dr_course.gd")

## Writes one bake scene per course for dot-lighting's baker: the course built exactly as a
## client builds it, its still boxes kept (each under the node and mesh name it has at run time,
## with its second UV set), the sun, the fill and the sky, a LightmapGI added and the course's
## fingerprint recorded. tools/bake_lightmaps.sh runs this and then the bake; nobody needs to run
## it alone.
##
##   xvfb-run -a godot --path . res://tools/lightmap_scenes.tscn -- --out=res://lightbake_work [--courses=dr_quarry,dr_temple]
##
## Under a display, not --headless: a headless process keeps no mesh or image data to save.
##
## [b]What the bake sees, and what it must not.[/b] Only pieces [method DrCourse.is_bakeable]
## says are still and opaque. Movers, turntables, every trap part, the gate, the lethal pieces
## and the buttons are left out of the scene altogether: they stay dynamic and are lit live by
## the sun, and the probes the bake generates give them its bounce. Leaving them out also means
## nothing bakes a shadow or a bounce from a part that is not there a second later. The sun gives
## only its bounce (BAKE_DYNAMIC) because it stays live (its shadows are how a runner reads where
## a trap is); dot-lighting's fill is left out (BAKE_DISABLED), being already "more sky", which
## the environment gives the bake. A course has no lamps. Changing any of that changes what a bake
## means: bump DrCourse.BAKE_VERSION.

## Per course: LightmapGI settings for DotLightBake.prepare.
const SETTINGS := {
	"default": {"quality": LightmapGI.BAKE_QUALITY_MEDIUM, "bounces": 3, "texel_scale": 1.0},
	# Half the texels each way: at full density its 456 pieces were 4.9 MB, more than the other
	# five courses together.
	"dr_sections": {"quality": LightmapGI.BAKE_QUALITY_MEDIUM, "bounces": 3, "texel_scale": 0.5},
}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return fallback


func _run() -> void:
	var out := _arg("out", "res://lightbake_work")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	var catalogue := DrCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	var wanted := _arg("courses", "")
	var ids: Array = catalogue.courses.keys()
	ids.sort()
	var written := 0
	DrCourse.use_bakes = false
	DrCourse.for_bake_scene = true

	for id: StringName in ids:
		if wanted != "" and not wanted.split(",").has(String(id)):
			continue

		var course := DrCourse.new()
		course.draw_world = true
		add_child(course)
		var built := course.build(catalogue.courses[id])

		if not built.ok:
			printerr("LIGHTMAP_SCENE fail %s %s" % [id, built.error.message])
			continue

		var scene := _bake_scene(course)
		var path := out.path_join("%s.tscn" % id)
		var packed := PackedScene.new()
		packed.pack(scene)
		var saved := ResourceSaver.save(packed, path)
		print("LIGHTMAP_SCENE %s %s %s" % ["ok" if saved == OK else "fail", id, path])
		written += 1 if saved == OK else 0
		scene.free()
		remove_child(course)
		course.free()

	get_tree().quit(0 if written > 0 else 1)


func _bake_scene(course: DrCourse) -> Node3D:
	var root := Node3D.new()
	root.name = "Bake"
	var settings: Dictionary = SETTINGS.get(String(course.id()), SETTINGS["default"])
	var kept := 0

	for child in course.get_children():
		if not (child is Node3D):
			continue

		var mesh := _bakeable_mesh(child)

		if mesh == null:
			continue

		# The same names and nesting as the course has at run time: a lightmap names its
		# meshes by path from the LightmapGI, which is a child of the course there and of
		# this root here.
		var holder := Node3D.new()
		holder.name = child.name
		holder.transform = (child as Node3D).transform
		var copy := MeshInstance3D.new()
		copy.name = mesh.name
		copy.mesh = mesh.mesh
		copy.material_override = mesh.material_override
		copy.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		holder.add_child(copy)
		root.add_child(holder)
		kept += 1

	var lighting := course.get_node("Lighting").duplicate() as Node3D
	root.add_child(lighting)

	for node in lighting.get_children():
		if node is DirectionalLight3D:
			# The sun first (DotLightRig adds it before the fill).
			node.light_bake_mode = Light3D.BAKE_DYNAMIC if node == lighting.get_child(0) else Light3D.BAKE_DISABLED

	DotLightBake.prepare(root, course.light_fingerprint(), DrCourse.BAKE_PATH % String(course.id()), settings)
	_own(root, root)
	print("LIGHTMAP_SCENE kept %s %d of %d pieces" % [course.id(), kept, course.pieces.size()])
	return root


## The piece body's baked mesh, or null for a piece that is not baked.
func _bakeable_mesh(body: Node) -> MeshInstance3D:
	for node in body.get_children():
		if node is MeshInstance3D and node.has_meta(&"dr_bakeable"):
			return node
	return null


func _own(node: Node, owner_node: Node) -> void:
	for child in node.get_children():
		child.owner = owner_node
		_own(child, owner_node)
