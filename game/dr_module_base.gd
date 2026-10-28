extends DotGameModule

## The console commands of `dr_module.gd` and the delivered-course reload, split out to keep the module under the size budget. No `class_name`: a module in a pack cannot have one.

const DrGame := preload("dr_game.gd")
const DrNetBridge := preload("net/dr_net_bridge.gd")
const DrPlayer := preload("dr_player.gd")
const DrServices := preload("dr_services.gd")
const DrVote := preload("dr_vote.gd")

## The players' vote for the next course; null when it could not be built.
var vote: DrVote = null


## The courses the SERVER names (its map config, via [DotGameContent]), fetched and added to the
## catalogue; returns how many documents they held. Server-only: clients get the course in STAGE.
## Call after EVERY catalogue load, because `load_from` forgets what was read before.
func _add_delivered_courses(world: DrGame) -> int:
	if server == null or world.catalogue == null:
		return 0

	var read := 0

	for root in await DotGameContent.map_dirs(server, "courses"):
		read += world.catalogue.add_directory(root)

	return read
func _cmd_wish(ctx: DotCmdContext, side: int) -> void:
	var world := game as DrGame
	if world == null or ctx.session == null:
		ctx.reply("Only a player can choose a side.")
		return
	if not world.config.allow_side_choice:
		ctx.reply("Sides are drawn on this server.")
		return
	world.wish_side(DrNetBridge.player_key(ctx.session.userid), side)
	ctx.reply(
		"You will be drawn as an activator first." if side == DrGame.ACTIVATORS
		else ("You will only activate if nobody else can." if side == DrGame.RUNNERS else "Either side.")
	)
func _cmd_say(ctx: DotCmdContext) -> void:
	var text := ctx.rest()

	if text.strip_edges() == "":
		ctx.reply("Say what?")
		return

	if services == null or services.get("chat") == null:
		ctx.reply("This server has no chat.")
		return

	var announced: Variant = services.get("chat").call("announce", text, DrServices.CH_ALL)

	if announced is DotResult and not (announced as DotResult).ok:
		ctx.reply_error(announced)
		return

	ctx.reply("Said: %s" % text)
func _cmd_status(ctx: DotCmdContext) -> void:
	var world := game as DrGame

	if world == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.describe_lines())
func _cmd_net(ctx: DotCmdContext) -> void:
	if bridge == null:
		ctx.reply("No bridge; this server is not replicating anything.")
		return

	ctx.reply_lines(bridge.call("describe_lines"))

	if services != null:
		ctx.reply_lines(services.call("describe_lines"))
func _cmd_courses(ctx: DotCmdContext) -> void:
	var world := game as DrGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.catalogue.describe_lines())
	ctx.reply("playing: %s" % str(world.course_doc.get("id", "-")))
func _cmd_rotation(ctx: DotCmdContext) -> void:
	var world := game as DrGame

	if world == null or world.catalogue == null or not world.catalogue.has_rotation_file():
		ctx.reply("There is no maps.yml; every course rotates.")
		return

	var file := world.catalogue.rotation_file

	if ctx.argc() == 0:
		ctx.reply("Rotations: %s (active: %s)" % [", ".join(file.rotation_names()), file.active_name()])
		return

	var wanted := ctx.arg(0)
	var switched := world.catalogue.switch_rotation(wanted)

	if not switched.ok:
		ctx.reply(switched.error.message)
		return

	if vote != null:
		vote.refresh_courses()

	ctx.reply("Rotation: %s" % wanted)
func _cmd_maps_reload(ctx: DotCmdContext) -> void:
	var world := game as DrGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var read := world.load_rotation()

	if vote != null:
		vote.refresh_courses()

	ctx.reply("maps.yml read." if read.ok else read.error.message)
func _cmd_traps(ctx: DotCmdContext) -> void:
	var world := game as DrGame

	if world == null or world.stage == null:
		ctx.reply("No world.")
		return

	var tick := world.current_tick()

	for index in range(world.stage.trap_count()):
		var by: StringName = world.pressed_by.get(index, &"")
		var who: DrPlayer = world.players.get(by)
		ctx.reply("  %-20s %s%s" % [
			world.stage.trap_name(index),
			"ready" if world.stage.trap_ready(index, tick) else "spent",
			" (by %s)" % who.display_name if who != null else "",
		])

	if world.stage.trap_count() == 0:
		ctx.reply("This course has no traps.")
func _cmd_reload(ctx: DotCmdContext) -> void:
	var world := game as DrGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var loaded := world.catalogue.load_from(world.config.course_directory)
	loaded += await _add_delivered_courses(world)
	world.catalogue.apply_rotation(world.config.course_ids)

	if vote != null:
		vote.refresh_courses()

	ctx.reply("%d documents read; %d refused. The next round draws from them." % [
		loaded, world.catalogue.refused.size()])
