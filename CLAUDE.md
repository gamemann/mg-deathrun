# mg-deathrun

One long course of traps. Most players run it; one or more, drawn fresh each round, stand in a corridor beside it with a button for every trap. Whoever reaches the end is handed a weapon, and the first one there calls the activators down to settle it.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and each addon's own `CLAUDE.md` before working in it. This file is only about what this game decides. The courses are in `courses/`, a link to [mg-deathrun-maps](../mg-deathrun-maps), written by its `tools/build_courses.py`; `courses/README.md` is the format.

**Built 2026-10-05, in one session, from mg-wipeout's skeleton** (module, services, wire, client, HUD, spectate, progress, avatars, figure, beacon, textures — renamed `wo` → `dr` and then rewritten wherever they named a checkpoint, a knock or the final death). Where a comment says "mg-wipeout found…" or "mg-smash-copter found…", the finding is that game's and the line was kept because it is still true here.

## What this game is, versus the other eight

game-arena is a deathmatch, g2gfast a timer server, playground a sandbox, hungario an eating game, the lobby a lobby, buses asymmetric, smash-copter a floor that tips, wipeout scripted machinery that cannot hurt you. This is the second asymmetric one and the first where **the hazards are another player's decisions**: nothing on a course moves until an activator presses its button, every trap kills, and nothing comes back — no respawn, no checkpoint. The skill on one side is getting through; on the other it is timing.

## Layout

```
game/
  dr_config.gd       every rule a course is played under (the courses themselves are documents)
  dr_course_doc.gd   what a course IS: pieces, traps as parts on a timeline, the places; validated
  dr_course.gd       THE FILE. A document built; every trap a function of the tick and its press
  dr_catalogue.gd    every document the server has, the built-in practice course, which is next
  dr_controller.gd   DotFpsController with the pre/post-simulate hooks the course needs
  dr_player.gd       one person: movement, the carry after each tick, their side, their hands
  dr_rules.gd        a DotMatchRules whose outcome is whatever DrGame decided
  dr_game.gd         the simulation: the draw, the buttons, the deaths, the end, both kinds of bot
  dr_hud.gd          the clock, the side, who is left, the activator's traps and the button ahead
  dr_audio.gd        a trap, the gate, a death, the finish, the showdown
  dr_client.gd       one local player, alone or against a server; poses the course per frame
  dr_module.gd       the DotGameModule: cvars, dr_status / dr_courses / dr_traps / dr_reload, stand-ins
  dr_services.gd     chat, voice (team by default) and moderation over dot-game's base
  dr_vote.gd         the players' vote for the next course, over dot-vote
  net/               the codec (STAGE, TEAM, TRAP, FINISHED…), the link, the player behaviour, the bridge
courses/             link to ../mg-deathrun-maps/courses (generated there); README.md is the format
examples/            headless_run (92), headless_courses (every course played), headless_net (39), dedicated (34)
tools/               shot.sh/.gd — render a view; trace_run — where a stand-in runner goes
```

## Decision 1: a trap is a pure function of the tick and the tick it was pressed on

mg-wipeout's obstacles are functions of the tick alone, so nothing about them is ever sent. A trap has one more input — when its button was pressed — and **that input is the only thing about a trap that travels**: one reliable `TRAP` event, the trap's index and the tick it went on. From those, `DrCourse.extension(timing, seconds_since)` and `part_transform(part, e, running)` give every part's pose at every tick on both ends. The tick in the event is the PRESS's tick, not the arrival's: a client that started the clock on arrival would draw and predict every trap a round trip late. A client that hears of a press after it has already predicted past it re-poses the past correctly on its next reconciliation, because the replay asks the course where the trapdoor was at each replayed tick, and the course now knows. `headless_net` asserts the crusher in the same place on both ends at 39 ticks and 117 "does this kill" queries agreeing, and that a joiner's READY is answered with every trap already pressed and when.

**Killers are not solid; carriers are.** A lethal part is measured (`DrCourse.lethal_at`: five samples up the player's capsule against each part's box), never collided — a solid spike wall would push somebody out of itself before the test found them in it, and which way depends on resolution order, which two machines do not agree on. A solid part that moves (a trapdoor leaf, a rolling log, a falling block) carries whoever stands on it by the exact displacement `pose(t+dt)·pose(t)⁻¹·p − p`, inside the player's own tick, so a runner's client predicting itself is carried exactly as the server carries it (`headless_net`: the client's own player goes down with the block). **Whether a trap killed somebody is the server's**: a death arrives as an event, never predicted, because a client that decided it had died could decide it had not.

**Moving parts are STATIC bodies, teleported** — mg-wipeout's finding, unchanged: a kinematic body's new transform lands a physics step late, and a replay of six ticks in one frame would sweep all six against a trapdoor a frame old.

**A trap is parts on a timeline, not a kind.** Every trap in every course is `{button, timing {delay, out, hold, back}, parts [{at, size, move | turn | spin, solid, lethal, look}]}`. A trapdoor, a crusher, closing walls, a log that rolls, falling blocks, sinking floes, jaws, icicles, saws and fire are all that, so the validator, the builder, the death test and the carry each have one case. A lethal part that does not move is a hazard switched ON while the trap is out (fire) and is only drawn then; one that moves is lethal wherever it is, because where it is IS whether it is out.

## Decision 2: the course travels, whole, and is two corridors

A course is a JSON document the server reads and sends, normalised, in `STAGE` — mg-wipeout's Decision 2. **One document is the whole map**: the runners' corridor, the activators' walkway beside it with a button opposite every trap, the finish, and the end arena. A course with the arena in another file would be two documents that have to agree about where one stops.

**The courses are generated (in mg-deathrun-maps), because the two corridors have to agree along their whole length.** `tools/build_courses.py` lays a section — its floor, its trap, its button, its route points — at a cursor and moves the cursor on, then lays the walls and the walkway the length of what was built. It refuses two buttons closer than 2.6 m (the nearer would be pressed for the further), and `--check` fails if a file on disk is not what it would write. `headless_courses` plays every course: a stand-in runs it to the end, **every trap is sprung on somebody standing at its `victim` spot** (who must survive until the press and not after), an activator walks to every button, and both ends of the arena are stood in. Armed: a trap that cannot reach its victim fails it. A trapdoor whose leaves swing up instead of down does NOT fail it, and that is correct — the floor is open either way.

**The activator must be able to SEE the corridor.** The first render put the runners' right wall 0.8 m above the walkway and hid the near half of the corridor from the only person whose job is watching it. The wall stops level with the walkway now; a thin rail and an invisible clip (`"visible": false`, a piece kind of its own) keep the activator out. `tools/shot.sh --view=activator` is the check.

**Trap floors are drawn as floor.** A trap part that is not lethal defaults to the ground's role and the theme's tint: a trapdoor in the moving-ground orange is a trapdoor every runner walks round.

## Decision 3: the sides are drawn, and a round is decided by the game

Two fixed sides: `RUNNERS` (1) and `ACTIVATORS` (2). At the top of every round `DrGame._draw_sides` draws `config.activators_for(players)` — one per `players_per_activator` (10), at least one, at most `max_activators` (3), never everybody — **from everybody who was not an activator last round**, shuffled on the round's own seed. A rotation is fairer on paper and is gamed in practice (leave and rejoin to move up it); a draw that repeats reads as favouritism. `activator_may_repeat` turns the exclusion off. `headless_run` plays five rounds of four and asserts nobody drawn twice running.

`DrRules` returns CUSTOM when `DrGame` has decided. Every runner out → activators. Every activator out (including one who leaves) → runners. The clock → `timeout_winner` (activators by default). dot-match's backstop is the countdown plus the round plus a minute. A joiner mid-round is benched: watching, unhurtable, counted on no side — they cannot end a round by existing.

## The end

The first runner across the finish is teleported into the end arena with a weapon drawn from the pool, and **calls every activator down** (`Phase.SHOWDOWN`): armed (`activator_weapon`, or the pool), at `activator_health_scale` (1.5) times health because it is one against several, and everybody untouchable for `arrival_grace_seconds` on arrival. The buttons stop: an activator at the end presses nothing, so a runner still on the course runs it with nobody pressing — the reward for the runner ahead. Every later finisher arrives armed the same way.

## Credit

A trapdoor kills nobody; the spikes under it do. So `_watch_course` remembers the last running trap whose zone each runner was in (`_credit`), and a fall or a pit within `CREDIT_SECONDS` (4) is that trap's — credited to whoever pressed it (`pressed_by`), as dot-combat damage with them as the attacker, so the kill feed, dot-match and `DrProgress.TRAP_KILLS` all agree.

## Stand-ins

**Runners** follow the document's `route`. A `jump` point is where a jump LANDS; the take-off is wherever a ray finds no floor ahead (`_floor_at`, through the world layer, so an open trapdoor is not a floor). Each rule was earned by `tools/trace_run`:

- The first version named take-off points too, and aimed the jump at the take-off point it was standing on — backwards from a step past it. It jumped off the first block into the spikes behind it.
- **Stop after landing, then step back to the middle** (`_bot_settle`) before running at the next landing: a jump taken the tick after a landing keeps the last jump's momentum, and a bot that never stopped landed a metre and a half wide of the second floe, every time; one that stopped at the far edge had no run-up and fell short into the pool.
- **Jump at the edge, or earlier only if fast enough** (speed × a standing jump's airtime ≥ the distance to the landing): from the middle of a small block the stride ahead is already over the gap, and the bot took off at walking pace.
- **The air brake is measured along the velocity**, not along the line to the target (mg-wipeout's): a block half a metre to the side projected a two-metre overshoot onto nothing, and the bot stopped braking over the block it then sailed past. The brake is the constant deceleration `2·over/t²`.

**Activators** walk straight along the walkway to the button of the ready trap whose zone the nearest live runner is closest to (never one wholly behind the runners), and press it once a runner has been in its zone for `bot_trap_delay` (0.25 s). Straight walking is why every course's walkway is straight; `headless_courses` walks to every button.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"; done
godot --headless --path . res://examples/headless_run.tscn       # 22 sections, 92 checks
godot --headless --path . res://examples/headless_courses.tscn   # every course played (40 checks today)
godot --headless --path . res://examples/headless_net.tscn       # 9 sections, 39 checks
godot --headless --path . res://examples/dedicated.tscn          # 8 sections, 34 checks, and the exit probe
../mg-deathrun-maps/tools/build_courses.py --check               # the courses are what the builder writes
godot --headless --path . res://tools/trace_run.tscn -- --course=dr_ice_works --every=0.25
tools/shot.sh --view=activator
tools/shot.sh --view=trap --trap=ice_jaws --after=0.25 --dr-course-ids=dr_ice_works
```

`headless_courses` drives ticks without waiting on physics frames (all three courses take four seconds), legitimate only because every moving body is a static body written straight into the physics server and every ray reads it directly. Every suite counts sections and checks; `headless_run`'s and `dedicated`'s totals were armed by being wrong (both fired), and `headless_courses`' victim check was armed by stopping the jaws.

## What running it found

- **A round ended under the test that was measuring it.** The one runner caught by a falling block ends the round, intermission is zero in the suite, and the next round stood them back up at the start — so "is the rider dead" read false about a rider who had died. The checks read the death events now.
- **A stand-in jumped backwards**, fell short, sailed past a block and missed a floe sideways: the four rules under Stand-ins.
- **The weapon handout reached nobody without the module.** mg-wipeout wired `player_armed` to the bridge in the module, so the net suite (which has no module) never heard it. The bridge connects it itself.
- **The activator could not see the near half of the corridor**, trap floors were painted as traps, snowmen were green, and the end arena was magenta under a warm sun — all four found by rendering, none by a check.

## Delivery

The courses are their own repository and pack, [mg-deathrun-maps](../mg-deathrun-maps), split out on 2026-10-06 the way mg-wipeout's were: `courses/` here is a dot-bootstrap link (`.gitignore` names it), `game.yml` names `gamemann/mg-deathrun-maps` under `server_dependencies`, and `DrModule._add_delivered_courses` adds that mount's `courses/` to the catalogue. It is never in a client's content sync. A new course reaches servers by a release there and nothing else.

## Choosing a side, unseen activators, points and the Tab board (2026-10-06)

From the brief. **A player chooses a side** in chat (`!activator`, `!runner`, `!any`: module commands, so chat reaches them as it reaches every command): `DrGame._draw_sides` still shuffles on the round's seed and still skips last round's activators, then orders the hat volunteers, the undecided, and last anybody who asked to run, who is drawn only when the round would otherwise have no activator, because it must have one (`allow_side_choice`). **The ratio is one activator per 8 players, at most 6** (was 10 and 3): the brief asked for about five to forty, which the old numbers could never reach. **Runners do not see the activators** behind the walls (`activators_seen` off): a runner's client draws them as it draws its own body, not at all, except in the showdown. **Points**: `winner_points` (10) to everybody on the winning side and `first_across_points` (5), replicated as `net_points` with `net_ping` (dot-server's session ping), on dot-ui's `DotScoreboardScreen` under Tab with a colour swatch, the name, the side, points and ping. Not rendered here: the board is the component rendered in mg-wipeout the same night. `headless_run`'s *a player's choice of side counts in the draw* (3 checks), the ratio checks, and a points check on the runners' win.

## The course vote (2026-10-06)

The brief asked for map voting. **A round here is a course**, so dot-vote's ROUND_END trigger — open at a round's end, apply at the next one's — is one course late. `DrVote` uses MANUAL instead: a ballot opens `dr_vote_after` (20) seconds into every course and is applied at the round's end (`apply: END_OF_ROUND`), when `DrGame.next_course_id` is set and the next `_lay_out_course` uses it once. A rocked vote also waits for the round's end (`rtv_apply`), because changing the floor mid-round kills everybody on it. No time limit (`duration_sec` 0), the current course is on the ballot, and the cooldown is off: a server with two courses would otherwise offer nothing. Stand-ins are not voters, so a server of stand-ins never opens one. dot-vote's whole command set comes with it (`!vote`, `!rtv`, `!nominate`, `setnextmap`…), and the client shell draws the ballot from the `map_ballot` notice. An owner reshapes any of it in `user://cfg/deathrun_vote.json` or `game.yml`'s `metadata: course_vote:`, keyed as `DotVoteRules`; `{"enabled": false}` leaves the rotation alone. `dedicated`'s *the course vote* (7 checks) casts one vote and lays the course it chose. Its first version awaited a frame between the round's end and the check, and a stand-in round that started in that frame laid the voted course itself: the check is synchronous now. Not yet tried in a browser.

## The tell (2026-10-06)

A trap waits `trap_tell_seconds` (0.35) after its button before it moves, and its parts flash red through it, so reading the activator is a skill. **Written into the document**, not into either end: `DrGame.with_tell` adds it to every trap's `delay` (and records it as `timing.tell`) before the server builds the course and sends it, so a client predicts the trap at exactly the server's tick. Only in `_lay_out_course`, where the catalogue's documents are pristine, so a rebuild never adds it twice. The flash is a `material_overlay` per part instance (`DrCourse._draw_tell`), drawn only: a trapdoor that shook would carry whoever stood on it. 0 restores the instant trap. `headless_run` checks the trap tells and nobody moves, then they fall; `headless_net` waits the tell out before it expects the client's player to go down. Rendered: `tools/shot.sh --view=trap --trap=ice_jaws --after=0.05`.

## Still to do

In the order they are worth doing.

1. **Put it live.** The remote is `git@github.com:gamemann/mg-deathrun.git`; the repository has not been created on GitHub or pushed. Then a `content/deathrun/` and a `deathrun_client` suite in dot-server-deploy, the way `wipeout_client` checks a delivered wipeout — the one suite that runs a game from a mounted pack.
2. **Bunny-hop sections.** `auto_bunny_hop` and the air control are there; no course yet has a stretch built for them.
3. **A world model in a watcher's hands**, as mg-smash-copter's list says.
4. **Sounds for the machinery**: a trapdoor's bang, a saw's whine, the crusher's thud — today every trap is one synthesised impact.
