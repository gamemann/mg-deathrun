# Testing

`./game.sh test` parses every script and runs the five suites; `./game.sh test <suite>` runs one. `../mg-deathrun-maps/tools/build_courses.py --check` confirms the courses on disk are what the builder writes.

| Suite | What it covers |
| --- | --- |
| `examples/headless_run` | the simulation: the draw (five rounds, nobody twice running), side choice, the ratio, points, the tell, credit, the end, the client's settings and Escape |
| `examples/headless_courses` | every course played: a stand-in runs it to the end, **every trap is sprung on somebody at its `victim` spot** (who must survive until the press and not after), a runner on every `spared` spot survives, an activator walks to every button, both ends of the arena are stood in, and the known traps' sounds |
| `examples/headless_net` | over a loopback: traps posed the same on both ends, "does this kill" agreeing, a joiner answered with every pressed trap, the client's own player carried down by a block (after waiting out the tell), the end and the weapon in a watched hand, **a shot that lands told as HIT to the shooter alone** (a second ready peer hears none; a hit taken is not a marker) and the owner's magazine crossing for `DrClient.correct_drawn` (armed: without the HIT send, or with it broadcast, it fails), and **no engine error over the whole run** (an `EngineErrors` logger: a toy pulled out of the tree after a mid-tick course rebuild printed six on every green run; armed) |
| `examples/dedicated` | as a server: the console, the course vote laying the course it chose, and the exit probe |

## Rules

- **Every suite counts sections and checks**; `headless_courses` counts its victim and spared checks into its total.
- **`headless_courses` drives ticks without waiting on physics frames.** That is legitimate only because every moving body is a static body written straight into the physics server and every ray reads it directly. A kinematic or rigid body in a course would break that.
- **Read death events, not a later state.** A round can end under the test that is measuring it (intermission is zero in the suite) and the next round stands the dead back up.
- **Checks around a round boundary are synchronous.** The vote check once awaited a frame between the round's end and its assertion, and a stand-in round started in that frame.
- **Some trap faults are invisible to the victim check**: a trapdoor whose leaves swing up instead of down still opens the floor, and passes. Render it.

## Renders and sound

`tools/shot.sh --view=activator` (can the activator see the corridor), `--view=trap --trap=<id> --after=<s> --dr-course-ids=<course>` (a trap mid-motion; `--after=0.05` shows the tell), `--view=third --board` (the Tab board), `--view=end` (the end arena; `--end-wait=N` waits for a weapon switch to finish). The activator's view, the trap floors, the colours and the end arena's lighting were all found by rendering. `tools/audio_probe` (xvfb only) plays the five trap sounds under ALSA.

## Delivery

dot-server-deploy's `examples/deathrun_client` boots the delivered pack, joins with a real client over a real socket, checks the courses are mounted where `_add_delivered_courses` looks, and that the client builds the server's course and traps from the document.

`examples/headless_workshop` covers the Workshop against a fixture `DotContentIndex` (never the shared one): a solo pack course is listed as "Name [Pack]" and drawn, an online session lists none, a `map_kind` the game does not accept is left out, the game's own ids win, and the ballot follows the same rules. `tools/shot.sh --view=maps` renders the M menu with a fixture pack.
