extends DotConfig

## Every number this game has, layered like every other [DotConfig] in the family.
##
## [code]exported defaults < JSON file < environment < command line[/code], identically to
## dot-server, dot-cloud and the other games. Nothing here reads
## [code]OS.get_cmdline_args[/code] itself.
##
## [b]Metres and seconds.[/b] The courses are documents in the same units (see
## [DrCourseDoc]), so a length a mapper writes and a length this file tunes against are the
## same number with no ratio between them.
##
## [b]What is NOT here is the courses, and that includes the traps.[/b] How long a trapdoor
## stays open, how far a spike wall reaches and how long before a button can be pressed again
## are the course document's, because they are part of the map: a mapper times a trap against
## the corridor it is in. This file is the rules every course is played under.

# --- The round -------------------------------------------------------------

@export_group("The round")

## Seconds the runners stand behind the start gate before it drops.
##
## [b]Not zero, and the activator is the reason.[/b] The activator is put in their own
## corridor in the same tick the runners are put on the pad, and a gate that dropped at once
## would have the fastest runner past the first trap before the activator had turned round.
@export_range(0.0, 30.0, 0.5) var countdown_seconds: float = 5.0

## Seconds a round runs before it is called on the clock.
##
## A course document may ask for less (`round_seconds` in the document); this is the
## ceiling, so a mapper cannot make a server run one course for an hour. Five minutes is
## what the round-based servers this game is modelled on give a course.
@export_range(30.0, 1800.0, 5.0) var round_seconds: float = 300.0

## Seconds a player is untouchable after being put in the end arena.
##
## [b]Not zero, for the teleport.[/b] A runner who crosses the finish lands in a room with
## somebody already holding a gun, and dying on the tick you arrive is a death nobody could
## have done anything about.
@export_range(0.0, 10.0, 0.25) var arrival_grace_seconds: float = 1.5

## Seconds between rounds.
@export_range(0.0, 60.0, 1.0) var intermission_seconds: float = 6.0

## Seconds of the round's final killcam, added to the intermission (`mp_killcam_time`); 0 is off. Not added when the intermission is 0.
@export_range(0.0, 30.0, 0.5) var killcam_seconds: float = 7.0

## Seconds of warmup before the first round. 0 starts immediately.
@export_range(0.0, 300.0, 1.0) var warmup_seconds: float = 8.0

## Who wins a round the clock ends: 2 the activators, 1 the runners, 0 nobody.
##
## [b]The activators, by default, because the runners had to get there.[/b] A round that runs
## out of time is one where nobody reached the end and finished it, and on the servers this
## game is modelled on that is the trap side's round. An operator who disagrees has a cvar.
@export_enum("draw", "runners", "activators") var timeout_winner: int = 2

# --- The sides -------------------------------------------------------------

@export_group("The sides")

## One activator for every this many players, and always at least one.
##
## [b]Eight, which on a full server of twenty-four is three and on forty is five.[/b] One
## person with every button on a crowded server cannot keep up with a course's worth of
## runners spread along it. It was ten (at most three) until 2026-10-06; the brief asked for
## about five activators to forty runners, which ten and three could never reach.
@export_range(2, 64, 1) var players_per_activator: int = 8

## The most activators a round has, whatever the count above asks for. More than six and the
## buttons are fought over.
@export_range(1, 8, 1) var max_activators: int = 6

## Whether somebody who was an activator last round may be drawn again this round.
##
## [b]Off, and it is the most-asked-for rule on every server of this kind.[/b] Being the
## activator is the role everybody wants a turn at; drawing the same person twice running is
## read as the server playing favourites even when it was a fair draw.
@export var activator_may_repeat: bool = false

## Whether a player's own choice of side counts (`!activator`, `!runner`, `!any` in chat):
## volunteers are drawn first, and somebody who asked to run is drawn only when nobody else
## can be. Off, everybody is in the one hat.
@export var allow_side_choice: bool = true

## Whether a runner sees the activators. Off by default: they stand behind the course's
## walls watching, and the brief is that the runners cannot see them. In the showdown they
## are always seen, because they are fighting.
@export var activators_seen: bool = false

## Points for each player on the side that wins a round, and for the first runner across.
## They add up over a match and show on the Tab board.
@export_range(0, 100, 1) var winner_points: int = 10
@export_range(0, 100, 1) var first_across_points: int = 5

# --- The players -----------------------------------------------------------

@export_group("The players")

@export_range(1.0, 400.0, 1.0) var player_health: float = 100.0

## How fast a player runs, in m/s.
@export_range(1.0, 20.0, 0.1) var run_speed: float = 7.0

## What fraction of [member run_speed] holding the walk key gives.
@export_range(0.1, 1.0, 0.01) var walk_speed_scale: float = 0.45

## Metres a standing jump rises.
@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.2

## Metres per second squared, for everything.
##
## [b]Here rather than in `project.godot`, because a project setting does not travel with
## a delivered game.[/b] A pack mounted into the server tool's project runs at ITS setting.
## Applied to the world's own physics space by [DrGame].
@export_range(1.0, 60.0, 0.5) var gravity: float = 20.0

## Whether holding jump hops again the moment a player lands.
##
## [b]Off by default, and the courses are why.[/b] Every gap on a course is measured against a
## running jump at the run speed (the suite checks it); chaining hops clears gaps that were
## meant to be the hard part. A server that wants the bunny-hop sections of the older courses
## to be a skill rather than a timing turns this on — the air strafing is there either way.
@export var auto_bunny_hop: bool = false

## How much a player can steer in the air. The round-based shooters' feel at the default:
## enough to strafe round a corner mid-jump, not enough to turn back.
@export_range(0.0, 200.0, 1.0) var air_accelerate: float = 30.0

# --- The traps -------------------------------------------------------------

@export_group("The traps")

## Metres from an activator's eyes a button can be pressed from.
@export_range(0.5, 6.0, 0.1) var button_reach: float = 2.2

## How directly an activator has to look at a button to press it, as the cosine of the most
## the aim may be off. 0.5 is sixty degrees either side.
##
## [b]Loose on purpose.[/b] A button is pressed while the runners are in the trap, and an
## activator watching the trap is not looking at the button; a strict cone would turn every
## press into a turn of the head and a missed trap.
@export_range(-1.0, 1.0, 0.05) var button_cone: float = 0.5

# --- The courses -----------------------------------------------------------

@export_group("The courses")

## Which courses this server may play, by id. Empty means every one it has.
@export var course_ids: PackedStringArray = PackedStringArray()

## Seconds between a button being pressed and its trap moving, added to every trap's own delay:
## the tell. The trap's parts flash red for it, so a runner who is watching can read the
## activator and jump. 0 fires on the press, as it did before 2026-10-06.
@export_range(0.0, 3.0, 0.05) var trap_tell_seconds: float = 0.35

## Whether the next course is drawn at random (seeded) rather than taken in order.
@export var shuffle_courses: bool = true

## The file that says which courses this server ROTATES; the default stem makes dot-map look through its tiers for `maps.yml` in `cfg/game/mg-deathrun/dot_map/` (shipped) or `cfg/server/addons/dot_map/` (operator; dot-map's
## `DotMapRotationFile`: named rotations, `random` or `cycle`, wildcards, command names). Empty, or no such file, rotates every course. A course it
## leaves out stays installed (the map menu and an admin's change load it); it is only never
## drawn, balloted or nominated. A rotation in the file replaces [member shuffle_courses].
## `sv_map_rotation_file`.
@export var map_rotation_file: String = DotMapRotationFile.DEFAULT_STEM

## Where course documents are read from, beside the one built into this game. Relative to
## this game's own root, so a delivered pack reads its own copy.
@export var course_directory: String = "courses"

## Seed every random choice in a round is drawn from: the course, the activators, where
## everybody stands, the weapons at the end.
##
## [b]A seed rather than a schedule, and reproducible on purpose.[/b] Two servers on one seed
## play the same round, which is what makes "the round where the same person was drawn three
## times" a bug report somebody can act on.
@export var seed_value: int = 20261005

# --- The end ---------------------------------------------------------------

@export_group("The end")

## Which weapons a runner may be handed at the end, by id from the pack. Empty means a
## sensible default set.
@export var weapon_pool: PackedStringArray = PackedStringArray()

## The weapon every activator is handed when they are called to the end. Empty draws one from
## the pool like a runner.
@export var activator_weapon: String = ""

## How much more health an activator has in the end arena, as a multiple.
##
## [b]Above one, because it is one against several.[/b] The first runner across fights alone,
## but every runner after joins in, and an activator at the same health as each of them is
## not a fight the last few runners have to finish.
@export_range(0.5, 10.0, 0.1) var activator_health_scale: float = 1.5

# --- Bots ------------------------------------------------------------------

@export_group("Bots")

## How many players the server keeps in the round by adding stand-ins.
##
## [b]Three by default:[/b] an activator and two runners is the smallest round that is a
## round, and one person on an empty server is then a runner with somebody pressing buttons
## at them — or the activator, with somebody to press them at.
@export_range(0, 24, 1) var minimum_players: int = 3

## Deprecated: what `dr_bot_spread` last set `bot_aim_error` to. A stand-in's aim is dot-bot's
## ([DotBotAim] on `bot_difficulty`); nothing reads this but the alias.
@export_range(0.0, 45.0, 0.5) var bot_aim_spread_degrees: float = 7.0

## How likely a stand-in runner is to mistime a jump, in a hundred.
@export_range(0.0, 100.0, 1.0) var bot_fumble_chance: float = 8.0

## How late a stand-in activator presses a button, in seconds after a runner is in the trap.
##
## [b]Not zero.[/b] A bot that pressed on the tick a runner entered would be a reflex no person
## has, and a trap that always fires at its earliest moment is a trap a runner learns to
## stand outside of. A quarter of a second is a quick person.
@export_range(0.0, 3.0, 0.05) var bot_trap_delay: float = 0.25

# --- Watching --------------------------------------------------------------

@export_group("Watching")

## Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody.
@export_enum("anybody", "own side", "nobody") var spectate_camera: int = 0

# --- Progress --------------------------------------------------------------

@export_group("Progress")

## Whether the server counts per-player numbers and awards achievements at all.
@export var keep_progress: bool = true

## Where lifetime achievement progress is written. Empty keeps it in memory.
@export var progress_directory: String = ""

## Whether the numbers and the unlocks are reported to the backbone. Needs a credential.
@export var report_progress: bool = false


func env_prefix() -> String:
	return "DR_"


func cli_prefix() -> String:
	return "--dr-"


## How many activators a round with [param players] people in it has.
func activators_for(players: int) -> int:
	if players < 2:
		return 0

	var wanted := maxi(players / maxi(players_per_activator, 2), 1)
	# Never everybody: a round with no runner in it is a round nobody can lose.
	return clampi(wanted, 1, mini(max_activators, players - 1))


func validate() -> DotResult:
	if round_seconds <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "A round has to last some time.")

	if max_activators < 1:
		return DotResult.fail(DotError.CODE_INVALID, "A round needs at least one activator.")

	if timeout_winner < 0 or timeout_winner > 2:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"timeout_winner is %d; it is 0 (draw), 1 (runners) or 2 (activators)." % timeout_winner,
		)

	if spectate_camera < 0 or spectate_camera > 2:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"spectate_camera is %d; it is 0 (anybody), 1 (own side) or 2 (nobody)."
				% spectate_camera,
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"round": "%.0f s" % round_seconds,
		"activators": "1 per %d, at most %d" % [players_per_activator, max_activators],
		"timeout": ["draw", "runners", "activators"][timeout_winner],
		"courses": "all" if course_ids.is_empty() else ",".join(course_ids),
		"gravity": "%.1f m/s2" % gravity,
		"bunny_hop": "auto" if auto_bunny_hop else "off",
		"bots": minimum_players,
	}


## Overridden to print what this game is tuned to rather than every field.
##
## The signature carries the parent's `redact_sensitive` even though nothing here is a
## secret: a subclass that quietly narrows an override is a method that is silently the
## parent's at every call site that passes the argument.
func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("deathrun configuration")
	var facts := describe()
	for key: String in facts:
		lines.append("  %-14s %s" % [key, facts[key]])
	return lines
