extends SceneTree

## Rewrites cfg/game/mg-deathrun/config_*/game.yml from DrConfig's fields: godot --headless --path . --script tools/cfg_templates.gd

const DrConfig := preload("../game/dr_config.gd")


func _init() -> void:
	var binder := DrConfig.make_binder(DrConfig.new())
	var files := binder.template_files()
	for path: String in files:
		var res := DotPaths.write_text("res://" + path, files[path])
		print("%s %s" % ["wrote" if res.ok else "FAILED", path])
	quit()
