extends DotGameWorkbenchSuite

## mg-deathrun: the workbench over the config binder, one edit per profile set, the export and its cfg round trip.
## Run: godot --headless --path . res://examples/headless_workbench.tscn

const DrConfig := preload("../game/dr_config.gd")


func _make_config() -> DotConfig:
	return DrConfig.new()


func _make_binder(config: DotConfig) -> DotGameConfigBinder:
	return DrConfig.make_binder(config)
