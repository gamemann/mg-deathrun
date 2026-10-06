extends Node

const DrPlayer := preload("dr_player.gd")

## What a player keeps from a round: the numbers this game produces, and what they earn.
##
## [b]The numbers are the ones only this game has.[/b] A deathmatch counts kills; a course of
## traps counts both ends of a trap — how many courses somebody got to the end of, and as the
## activator how many runners their presses took. Each is declared once, in [method schema],
## counted as it happens and reported by dot-stats as a DELTA — "add one", never "now has
## forty" — so two servers reporting one player add up rather than overwrite.
##
## [b]Achievements are rules over those numbers and nothing else.[/b] dot-achievements never
## hears about a trap; it hears that a number moved, through [DotAchievementStatsLink] — which
## is the differencer between dot-stats' SESSION totals and a lifetime total, and the reason
## this is not one `connect`.
##
## [b]Stand-ins are never counted.[/b] An achievement a bot can earn is noise in every log an
## operator reads, and a stand-in's numbers are no player's numbers.
##
## [b]Server side, and on an offline client — wherever the world is authoritative.[/b]
##
## [b]A player's numbers are filed under their scoped profile key when they have one[/b] — see
## mg-wipeout's note, which this is, unchanged: [member durable_key_fn] supplies it, and
## without one the key is the world's id and lasts a connection.

const CHANNEL := "dr.progress"

# --- The numbers -------------------------------------------------------------

## Rounds a player was in from the start to the end.
const ROUNDS_PLAYED := &"dr.rounds_played"
const ROUNDS_WON := &"dr.rounds_won"
## A course run to its end.
const RUNS_FINISHED := &"dr.runs_finished"
## A course run to its end first.
const RUNS_FIRST := &"dr.runs_first"
## A round spent at the buttons.
const ACTIVATOR_ROUNDS := &"dr.activator_rounds"
## A button pressed that did something.
const PRESSES := &"dr.presses"
## A runner a trap you pressed took.
const TRAP_KILLS := &"dr.trap_kills"
const BEST_ROUND_TRAP_KILLS := &"dr.best_round_trap_kills"
## Somebody on the other side put down in the end arena.
const END_KILLS := &"dr.end_kills"
const DEATHS := &"dr.deaths"
## Caught by a trap, a pit or the drop.
const TRAP_DEATHS := &"dr.trap_deaths"

signal earned(player_id: StringName, title: String, points: int)

var stats: DotStatsTracker = null
var achievements: DotAchievementTracker = null
var link: DotAchievementStatsLink = null

## The world's own dictionaries, shared. See [DrSpectate] for why not a reference to it.
var players: Dictionary = {}
var sides: Dictionary = {}

## Players present when this round began. Only they have played it.
var _in_round: Dictionary = {}

## player id -> runners their traps took this round, for [constant BEST_ROUND_TRAP_KILLS].
var _round_trap_kills: Dictionary = {}

## `func(player_id: StringName) -> String`: the durable key to file this player under, or
## "" for none. Set by the module from dot-platform; see the class note.
var durable_key_fn: Callable = Callable()

## World id -> the key their numbers are filed under, and back. Fixed at [method record]'s
## first reading for them.
var _keys: Dictionary = {}
var _ids: Dictionary = {}


# --- The documents -----------------------------------------------------------

static func ids() -> Array[StringName]:
	return [
		ROUNDS_PLAYED, ROUNDS_WON, RUNS_FINISHED, RUNS_FIRST, ACTIVATOR_ROUNDS, PRESSES,
		TRAP_KILLS, BEST_ROUND_TRAP_KILLS, END_KILLS, DEATHS, TRAP_DEATHS,
	]


## Every number, once. [b]`publish` on the ones a player page would show[/b]; deaths and
## rounds played are inputs to a ratio rather than figures anybody reads.
static func schema() -> DotStatsSchema:
	var out := DotStatsSchema.new()
	_add(out, ROUNDS_PLAYED, DotStatsDef.Kind.COUNTER, "Rounds played", "rounds", false)
	_add(out, ROUNDS_WON, DotStatsDef.Kind.COUNTER, "Rounds won", "rounds", true)
	_add(out, RUNS_FINISHED, DotStatsDef.Kind.COUNTER, "Courses finished", "courses", true)
	_add(out, RUNS_FIRST, DotStatsDef.Kind.COUNTER, "Courses finished first", "courses", true)
	_add(out, ACTIVATOR_ROUNDS, DotStatsDef.Kind.COUNTER, "Rounds at the buttons", "rounds", true)
	_add(out, PRESSES, DotStatsDef.Kind.COUNTER, "Traps sprung", "traps", true)
	_add(out, TRAP_KILLS, DotStatsDef.Kind.COUNTER, "Runners trapped", "runners", true)
	_add(out, BEST_ROUND_TRAP_KILLS, DotStatsDef.Kind.BEST, "Most trapped in a round", "runners", true)
	_add(out, END_KILLS, DotStatsDef.Kind.COUNTER, "End arena knockouts", "kills", true)
	_add(out, DEATHS, DotStatsDef.Kind.COUNTER, "Deaths", "deaths", false)
	_add(out, TRAP_DEATHS, DotStatsDef.Kind.COUNTER, "Caught by a trap", "deaths", true)
	return out


static func _add(
	out: DotStatsSchema, id: StringName, kind: DotStatsDef.Kind, display: String,
	unit: String, publish: bool
) -> void:
	var def := DotStatsDef.make(id, kind, display)
	def.unit = unit
	def.publish = publish
	out.stats.append(def)


## What a player can earn, as rules over [method schema]'s numbers.
##
## [b]Every stat read here is one [method schema] declares and this file records[/b] — an
## achievement over a stat nothing reports never unlocks and nothing errors. The suite checks
## it both ways.
static func catalogue() -> DotAchievementCatalogue:
	var made: Array[DotAchievement] = []

	made.append(_sum(&"dr.made_it", "Made It", RUNS_FINISHED, 1.0, 10,
		"Run a course to its end.", &"dr.runner", 1))
	made.append(_sum(&"dr.old_hand", "Old Hand", RUNS_FINISHED, 25.0, 30,
		"Run twenty-five courses to their end.", &"dr.runner", 2))
	made.append(_sum(&"dr.first_through", "First Through", RUNS_FIRST, 1.0, 20,
		"Be the first runner to the end."))
	made.append(_sum(&"dr.at_the_buttons", "At the Buttons", ACTIVATOR_ROUNDS, 1.0, 10,
		"Spend a round as the activator."))
	made.append(_sum(&"dr.got_one", "Got One", TRAP_KILLS, 1.0, 10,
		"Catch a runner with a trap.", &"dr.trapper", 1))
	made.append(_sum(&"dr.trap_master", "Trap Master", TRAP_KILLS, 50.0, 30,
		"Catch fifty runners with traps.", &"dr.trapper", 2))
	made.append(_sum(&"dr.turned_tables", "Turned the Tables", END_KILLS, 10.0, 25,
		"Put ten people down in the end arena."))

	# A BEST: five in one round at the buttons, not five over a career.
	var full_house := DotAchievement.make(&"dr.full_house", "Full House", [
		DotAchievementRule.make(
			BEST_ROUND_TRAP_KILLS, 5.0, DotAchievementRule.Op.AT_LEAST,
			DotAchievementRule.Merge.HIGHEST
		),
	])
	full_house.description = "Catch five runners with traps in one round."
	full_house.points = 30
	made.append(full_house)

	# Secret: earned by the thing the game is about, long before anybody knows there is
	# anything to earn — and the joke only works afterwards.
	var pincushion := _sum(&"dr.pincushion", "Pincushion", TRAP_DEATHS, 50.0, 10,
		"Be caught by a trap fifty times.")
	pincushion.secret = true
	made.append(pincushion)

	var out := DotAchievementCatalogue.new()
	out.achievements = made
	return out


static func _sum(
	id: StringName, title: String, stat: StringName, target: float, points: int,
	description: String, series: StringName = &"", tier: int = 0
) -> DotAchievement:
	var out := DotAchievement.make(id, title, [
		DotAchievementRule.make(
			stat, target, DotAchievementRule.Op.AT_LEAST, DotAchievementRule.Merge.SUM
		),
	])
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


# --- Building ---------------------------------------------------------------

## [param directory] empty keeps achievement progress in memory; see
## [member DrConfig.progress_directory]. [param report] is [member DrConfig.report_progress].
func setup(directory: String, report: bool) -> DotResult:
	stats = DotStatsTracker.new()
	stats.name = "Stats"
	stats.schema = schema()
	stats.report_to_backbone = report
	stats.define_on_start = report
	add_child(stats)

	var counted := stats.start()

	if not counted.ok:
		return counted.wrap("deathrun stats")

	achievements = DotAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = catalogue()
	achievements.report_to_backbone = report
	# Not published: a server and a client in one process — every suite here — would fight
	# over one registry name, and the link below is handed the tracker directly.
	achievements.register_as = &""

	if directory != "":
		var file_store := DotAchievementStoreFile.new()
		file_store.directory = directory
		achievements.store = file_store
	else:
		achievements.store = DotAchievementStoreMemory.new()

	add_child(achievements)

	var awarded := achievements.start()

	if not awarded.ok:
		return awarded.wrap("deathrun achievements")

	achievements.unlocked.connect(_on_unlocked)

	link = DotAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	link.stats = stats
	add_child(link)

	return link.start().wrap("deathrun's stats-to-achievements link")


# --- Counting ---------------------------------------------------------------

## Files one reading for one person, and starts counting for them the first time.
##
## [b]Begun lazily, on the first number, and that is what keeps stand-ins out.[/b] A player
## is added to the world before a bridge or a client marks them a stand-in, so a check at
## join time would see every bot as a person; by the time anything is worth counting, the
## flag is set. The memory and file stores load synchronously, so the achievement tracker
## has them before the reading that follows.
func record(player_id: StringName, stat: StringName, value: float = 1.0) -> void:
	if stats == null:
		return

	var body: DrPlayer = players.get(player_id)

	if body == null or body.is_bot:
		return

	var key := _key(player_id)

	if not stats.has_player(key):
		stats.begin(key, body.display_name)
		_begin(key)

	var filed := stats.record(key, stat, value)

	if not filed.ok:
		# WARN: a number a player earned that nobody will ever see. It is a schema or a key
		# that is wrong, and it only ever happens for a reason worth looking at.
		DotLog.warn(CHANNEL, "a reading was refused", {
			"player": String(player_id), "stat": String(stat), "why": filed.error.message,
		})


## The key a player's numbers are filed under. Asked of [member durable_key_fn] once, then
## remembered; see the class note.
func _key(player_id: StringName) -> StringName:
	if _keys.has(player_id):
		return _keys[player_id]

	var key := player_id

	if durable_key_fn.is_valid():
		var durable := str(durable_key_fn.call(player_id))

		if durable != "":
			key = StringName(durable)

	_keys[player_id] = key
	_ids[key] = player_id
	return key


## Loads somebody's lifetime progress. A statement call, never assigned: the tracker's
## `begin` is a coroutine, and this is the family's pattern for starting one from code that
## is not — `await` inside, a bare call outside.
func _begin(player_id: StringName) -> void:
	var began: DotResult = await achievements.begin(String(player_id))

	if not began.ok:
		# WARN: this player will earn nothing this session, and they will not be told why.
		DotLog.warn(CHANNEL, "achievement progress could not be loaded", {
			"player": String(player_id), "why": began.error.message,
		})


## Saves somebody's progress as they go. See [method _begin].
func _end(player_id: StringName) -> void:
	var ended: DotResult = await achievements.end(String(player_id))

	if not ended.ok:
		DotLog.warn(CHANNEL, "achievement progress could not be saved", {
			"player": String(player_id), "why": ended.error.message,
		})


## Stops counting for somebody who left, and saves what they earned.
func leave(player_id: StringName) -> void:
	_in_round.erase(player_id)
	_round_trap_kills.erase(player_id)

	var key: StringName = _keys.get(player_id, player_id)
	_keys.erase(player_id)
	_ids.erase(key)

	if stats == null or not stats.has_player(key):
		return

	var _values := stats.end(key)
	link.forget(String(key))
	_end(key)


func session_values(player_id: StringName) -> DotStatsValues:
	return stats.session_values(_keys.get(player_id, player_id)) \
		if stats != null else DotStatsValues.new()


## The key [param player_id]'s numbers are filed under. For a console command and a suite.
func filed_under(player_id: StringName) -> StringName:
	return _keys.get(player_id, player_id)


# --- What the world reports -------------------------------------------------

func on_round_began() -> void:
	_in_round.clear()
	_round_trap_kills.clear()

	for id: StringName in players:
		_in_round[id] = true

		# Two activators is two rounds at the buttons, one each.
		if int(sides.get(id, 0)) == 2:
			record(id, ACTIVATOR_ROUNDS)


## A runner reached the end, [param place] first.
func on_finished(player_id: StringName, place: int, _seconds: float) -> void:
	record(player_id, RUNS_FINISHED)

	if place == 1:
		record(player_id, RUNS_FIRST)


## An activator pressed a button that did something.
func on_pressed(player_id: StringName) -> void:
	record(player_id, PRESSES)


## A round ended. [param winner] is a side, or 0 for a draw.
func on_round_over(winner: int) -> void:
	for id: StringName in _in_round.keys():
		if not players.has(id):
			continue

		record(id, ROUNDS_PLAYED)

		if winner > 0 and int(sides.get(id, 0)) == winner:
			record(id, ROUNDS_WON)

		var trapped := int(_round_trap_kills.get(id, 0))

		if trapped > 0:
			record(id, BEST_ROUND_TRAP_KILLS, float(trapped))

	_in_round.clear()
	_round_trap_kills.clear()


## Somebody is out. [param by] is who did it — the activator who pressed the trap, or who
## shot them — or empty for the course; [param why] is the world's reason.
func on_died(player_id: StringName, by: StringName, why: StringName) -> void:
	record(player_id, DEATHS)

	var trapped := why != &"shot"

	if trapped:
		record(player_id, TRAP_DEATHS)

	if by == &"" or by == player_id or not players.has(by):
		return

	if int(sides.get(by, 0)) == int(sides.get(player_id, 0)):
		return

	if trapped:
		record(by, TRAP_KILLS)
		_round_trap_kills[by] = int(_round_trap_kills.get(by, 0)) + 1
	else:
		record(by, END_KILLS)


func _on_unlocked(player: String, achievement: DotAchievement) -> void:
	# INFO: what an admin keeps. "I did the thing and was not told" is answered here.
	DotLog.info(CHANNEL, "an achievement was unlocked", {
		"player": player, "achievement": String(achievement.id), "points": achievement.points,
	})
	# Back to the world's id: the world tells the player, and the world knows them by that.
	earned.emit(_ids.get(StringName(player), StringName(player)),
		achievement.display_name, achievement.points)


func describe() -> Dictionary:
	return {
		"tracking": stats.players().size() if stats != null else 0,
		"in_round": _in_round.size(),
		"achievements": achievements.catalogue.size() if achievements != null else 0,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if stats != null:
		out.append_array(stats.describe_lines())

	if achievements != null:
		out.append_array(achievements.describe_lines())

	return out
