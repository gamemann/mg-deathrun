# Stand-ins

An empty server fills with stand-ins on both sides. Every rule below was earned with `tools/trace_run` (`-- --course=<id> --every=0.25` prints where a stand-in runner goes).

## Runners

Runners follow the document's `route`. **A `jump` point is where a jump LANDS**; the take-off is wherever a ray finds no floor ahead (`_floor_at`, through the world layer, so an open trapdoor is not a floor). Naming take-off points too made the bot aim at the take-off it stood on and jump backwards off the first block into the spikes.

- **Pace is measured**: `headless_courses` fails a stand-in whose average pace (route length / finish time) is under 75% of the run speed (measured 0.81-0.95; coasting after landings gave 0.72 on Ice Works).
- **Stop after landing by braking against the motion, not coasting** (coasting on friction cost most of a second a jump, and read as a bot walking slowly), **then step back to the middle** (`_bot_settle`) before running at the next landing. A jump taken the tick after a landing keeps the last jump's momentum (landed a metre and a half wide, every time); stopping at the far edge leaves no run-up.
- **Jump at the edge, or earlier only if fast enough** (speed × a standing jump's airtime ≥ the distance to the landing). From the middle of a small block the stride ahead is already over the gap, and the bot took off at walking pace.
- **The air brake is measured along the velocity**, not along the line to the target (mg-wipeout's finding): a block half a metre to the side projected a two-metre overshoot onto nothing. The brake is the constant deceleration `2·over/t²`.

## Activators

Activators walk straight along the walkway to the button of the ready trap whose zone the nearest live runner is closest to (never one wholly behind the runners), and press it once a runner has been in its zone for `bot_trap_delay` (0.25 s). Straight walking is why every course's walkway is straight; `headless_courses` walks one to every button.

**A winding walkway (converted maps).** A course may carry a `walkway` list (points, the last before each button naming the trap): the activator then walks those points in order with `bot_walk_toward`, not a straight line, and `_bot_target_trap` picks the next trap by route progress (`DrCourse.route_progress`: how far along the runners' route each runner and each trap's zone is) instead of straight-line distance, because on a snaking course the nearest zone by distance is often on another floor or the far side of a wall. `headless_courses` walks the stand-in to every button the same way. The planner that writes the walkway is mg-deathrun-maps' `tools/plan_route.py`.
