extends DotMenuSettings

const DrBindings := preload("dr_bindings.gd")

## A player's own settings and the menu that changes them: how fast the view turns, how wide
## it is, how loud things are, the window, and the look of the menu itself.
##
## [codeblock]
## var settings := DrSettings.new()
## add_child(settings)
## settings.setup()                    # loads, and pushes every value at what reads it
## settings.bind_look(sampler.tunables)
## settings.bind_camera(camera)
## settings.bind_audio(audio.manager)
## settings.open()                     # Escape does this in the client
## [/codeblock]
##
## [b]dot-menu's `DotMenuSettings` with this game's schema[/b] (2026-10-09). It was a 250-line
## copy of mg-wipeout's file — a manager, a `match` over four keys and a bare settings
## screen — and the same copy was in five other games. What is left here is what is this
## game's: where the document lives, and the stock keys it has nothing to apply to.
##
## [b]The scopes are the family's, not this game's.[/b] `sensitivity` is ACCOUNT under the
## shared `tmc_account` namespace — a person's hand, the same number in every game here.
## `field_of_view` is SERVER_CLAMPED: a wide view is an advantage a server may cap, and
## dot-settings gives a server no way to READ it. The volumes are this machine's.

const SCHEMA_VERSION := 1

## Where this game's own document lives. The shared account document is dot-settings'.
const SETTINGS_DIR := "user://deathrun_settings"

## The app's namespace. ACCOUNT settings are shared under dot-menu's `tmc_account`.
const APP_NAMESPACE := &"deathrun"

## The field of view the camera had before this existed, and still the default.
const DEFAULT_FOV := 92

## Stock keys nothing here applies: every sound is on the SFX bus, the client binds no
## effects, and the chat box has no switch.
const NOT_APPLIED: Array[StringName] = [
	&"ui_volume", &"shake_scale", &"allow_flashes", &"fx_quality", &"chat_window",
]


func _init() -> void:
	name = "Settings"
	directory = SETTINGS_DIR
	app_namespace = APP_NAMESPACE
	schema = schema_for()
	config = DotMenuConfig.new()
	config.brand_name = "Deathrun"
	# Help and Leave are dot-menu's stock: H opens help, Leave leaves the server or quits a
	# solo game. Every game in the family has both (the first play test found this one without
	# them). The keys are a table now ([DrBindings]), so the help screen lists them.
	bindings = DrBindings.make()
	var _layered := config.load_layered()


## The document: this game's field of view first, so it keeps its own default, then the
## stock settings it applies.
static func schema_for() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION
	s.add(DotSettingsDef.integer(&"field_of_view", DEFAULT_FOV, 70, 120, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))
	s.add(DotSettingsDef.boolean(&"reduce_motion", false, &"accessibility").with_scope(DotSettingsDef.Scope.ACCOUNT)
		.with_description("The end-of-round announcement appears at once, with nothing sliding, rising or bursting."))
	return DotMenuStock.declare(s, DotMenuStock.DEFAULT_GROUPS, null, NOT_APPLIED)


func setup(store: DotSettingsStore = null, with_menu: bool = true) -> DotResult:
	var made := super.setup(store, with_menu)
	if menu != null:
		var general := menu.page(&"general")
		if general != null:
			general.section("Comfort").add(DotMenuRow.toggle(&"reduce_motion", "Reduce motion",
				"The end-of-round announcement appears at once."))
	return made


## The help screen's goal and rules; the keys come from [DrBindings].
func _fill_help(help: DotMenuHelp) -> void:
	help.about = "One long course of traps. Most players run it; one or more activators, drawn fresh each round, stand on a walkway beside it with a button for every trap. Runners try to reach the end; activators try to catch them in the traps."
	help.add_text("Activators", "Stand at a button and press the use key while a runner is in its trap. Each trap shows its name when you look at its button.")
	help.add_text("The end", "Whoever reaches the end is handed a weapon, and the first one there calls the activators down to settle it.")
	help.add_section("Mouse", [["Left", "Fire, at the end; watch the next player while out"], ["Right", "Alternate fire; watch the one before while out"]], &"keys")
