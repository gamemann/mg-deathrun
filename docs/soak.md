# Bot soak

`./game.sh soak [course] [minutes]` runs `tools/soak.tscn`: four stand-ins in the real `DrGame` on one course, driven by dot-bot's `DotBotSoak` with dot-spawn's `DotSpawnWatch` for stuck and fell-out verdicts, ticked externally at 64 Hz. A map here is a course id from `courses/`. The game draws the sides itself, so four stand-ins are three runners and one activator at the buttons. Rounds run back to back (no warm-up or intermission); only a live runner that has not finished and is on an open course counts as a mover with a goal, so a dead or watching runner is never judged stuck. The report is `.godot/test-logs/soak-<course>.json` plus one `SOAK {...}` line (with `rounds`, `finishes` and `traps_fired`), and the exit code is 1 on failure. Deaths are the game, so the kill check is off; there is no navigation mesh, so off-nav and unreachable are off.

**Needs the linked `addons/dot_spawn`** (gitignored like the other links, made by dot-bootstrap or `ln -s ../../dot-spawn/addons/dot_spawn addons/dot_spawn`), and an `--import` after adding it so `DotSpawnWatch` and `DotBotSoak` are known classes.

First run, 2026-10-22, 1 simulated minute per course, all 19 courses: 19 pass, 0 fail, no stuck spell at all (longest 0.0 s: a runner is dead or arrived before it could stall), no fell-out, object growth under 6% (the one negative, dr_internet_2, is a collection), tick cost p95 0.6 to 3.9 ms, worst single tick 98 ms (dr_iceworld, a round change). Rounds in the minute ran from 1 to 31.

A 10-minute run on dr_temple covers round turnover: 68 rounds, 336 traps fired, pass, object growth 0.1%. dr_internet for 7 minutes: 4 rounds, 12 finishes, pass.

- On dr_aztecan, dr_internet and dr_parking_garage the activator stand-in fired no trap in a minute (`traps_fired` 0) and all three runners finished; every other course fired 5 to 336. That is a bot finding, not a soak failure: the activator never reaches or presses a button there. Filed on the nightly board.
- Courses with finishers turn over slowly (about one round in 100 s) because the round waits in the showdown; courses where the runners die turn over every few seconds.
