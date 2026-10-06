This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game, most of the server are **runners**, racing one long corridor full of traps. One or more players are drawn each round to be the **activators**: they stand on a walkway beside the corridor with a button for every trap — a trapdoor, closing spike walls, a crusher, a rolling log, sinking ice floes, saws, fire — and press them while the runners are in them. A trap is a death and nothing comes back. Whoever reaches the end is handed a weapon, and the first one there calls the activators down to settle it.

The game ships with three courses: a short practice run, **Ice Works** and **The Foundry**, all written as documents rather than scenes.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as early and partially tested.** It has four headless test suites and they pass — including one in which a stand-in runs every course to its end and every trap is sprung on somebody standing in it — but none of it has been in front of real players yet, and it has not yet been published as a pack. Expect rough edges, and please report anything you run into.

## A round

Everybody is put in place at once: the runners behind the start gate, the activators at the near end of their walkway. When the gate drops, the course is open.

- **Runners** run. Every trap is still until somebody presses its button, so the danger is a person: watch the activator, bait a trap, wait for it to be spent, then go. Get caught and you watch the rest of the round.
- **Activators** walk their walkway and press **E** at a button while somebody is in its trap. Most traps work once a round; the list down the right of the screen says which are left, and the line under the crosshair says which button E would press.
- **The end.** The first runner across the finish is handed a weapon in the end arena, and every activator is called down to it, armed and a little tougher, because it is one against several. Everybody who makes it after them arrives armed too.

Every runner caught is the activators' round. Every activator put down — or gone — is the runners'. If the clock runs out it is the activators' round, unless the server says otherwise.

The activators are drawn at random each round from everybody who was not an activator last round, one for every ten players.

## Running it

```bash
godot --path .                                                    # play it, alone, against stand-ins
godot --headless --path . res://examples/headless_run.tscn         # the simulation, 86 checks
godot --headless --path . res://examples/headless_courses.tscn     # every course played
godot --headless --path . res://examples/headless_net.tscn         # over the wire, 39 checks
godot --headless --path . res://examples/dedicated.tscn            # as a real server, 27 checks
tools/shot.sh --view=activator                                     # what the activator sees
tools/shot.sh --view=trap --trap=ice_jaws --dr-course-ids=dr_ice_works   # a trap, mid-run
```

Offline you play against three stand-ins: when you are a runner, one of them is at the buttons; when you are the activator, they run.

## Controls

| | |
| --- | --- |
| WASD, mouse | Run and look |
| Space | Jump |
| Shift | Walk — for a narrow ledge |
| Ctrl | Crouch |
| E | Press the button in front of you (activators) |
| Left mouse | Fire, at the end |
| Right mouse, R, 1–5 | Alt-fire, reload, weapon slots |
| F5 | First person / third person |

## Configuring a server

Every number is a cvar or an environment variable, layered `defaults < JSON < environment < command line` like everything else in this family. The ones an operator wants between rounds are live and write through to the running world.

```
dr_round_seconds 240           // the most a round runs (a course may ask for less)
dr_players_per_activator 8     // one activator for every eight players
dr_max_activators 2            // and never more than two
dr_activator_repeat 1          // last round's activator may be drawn again
dr_timeout_winner 0            // a round the clock ends is a draw (1 runners, 2 activators)
dr_activator_health 2          // activators twice as tough at the end
dr_autobhop 1                  // holding jump hops again on landing
dr_bot_trap_delay 0.5          // stand-in activators press half a second later
dr_min_players 6               // keep six in the round with stand-ins
```

`dr_course_ids` (on the command line or in the JSON file) limits a server to some courses. `dr_courses` lists what the server has and any document it refused, with the reason; `dr_traps` lists this course's traps and which are spent; `dr_reload` reads the course directory again for the next round; `dr_status` and `dr_net` say what the server is doing.

A moderator has dot-moderation's live tools: `noclip`, `freeze`, `speed`, `gravity`, `god`, `buddha`, `hp`, `slay`, `slap`, `rename`, the teleports, `blind` and `beacon`, and `respawn`, which puts somebody back at the start of their side alive. `give` and `strip` are refused: the weapons are what the end hands out.

## Writing a course

A course is a JSON document — a start, a corridor of pieces and traps, a walkway with a button for every trap, a finish and an end arena — and a server reads every one in `courses/`. [`courses/README.md`](courses/README.md) is the format. The courses live in their own repository, [mg-deathrun-maps](https://github.com/gamemann/mg-deathrun-maps), linked here as `courses/` and delivered to a server as a pack of their own. They are generated by its `tools/build_courses.py`, which lays them out section by section so the corridor and the walkway beside it always agree; it is also the quickest way to write a new one. A server sends the course to each client as the round begins, so players need no course files at all.

## What replicates, and what does not

| | |
| --- | --- |
| A player's own movement | **Predicted**, and corrected |
| Everybody else | Replicated and interpolated |
| **The course** | **Sent once, as a document** |
| **A trap** | **One event: which trap, and the tick it was pressed on.** Every part of every trap is worked out from that by each client on its own, so a runner standing on a trapdoor that opens is carried by their own prediction exactly as the server carries them |
| A death | The server's decision, as an event |
| Sides, the finish, the end | The server's decisions, as per-player state and events |

## The art

Every surface is [Kenney's](https://kenney.nl) **Prototype Textures**, tinted per course. The players are Kenney's Blocky Characters and the weapons are [zee-dot-weapons](https://github.com/gamemann/zee-dot-weapons)' own. All of it is **CC0**. Spikes, blades, fire and pools are drawn from primitives in code.

## What does not work yet

- **No trap gives a warning.** Every trap goes the tick its button is pressed; a shake or a glow before it goes is the next thing to add.
- **The machinery makes one noise.** A trap going off is one synthesised impact, whatever it is.
- **Stand-ins are simple.** A stand-in runner follows the course's route and does not watch the activator; a stand-in activator presses the trap the nearest runner is in.
- **No settings screen**, for the reason mg-smash-copter gives: there is no menu to put one in.

## Licence

MIT. See [LICENSE](LICENSE).

The art is the exception, and it is a more permissive one: the prototype textures, the characters and the weapon models are CC0 1.0, public domain with no attribution required. Each kit's own licence text ships unchanged beside the files it covers.

## Voting for the next course

Part way into every course the players vote for the next one (`!vote 2`, `!rtv`, `!nominate dr_foundry`), and the next round plays the winner. A server owner configures it in `user://cfg/deathrun_vote.json`, keyed as dot-vote's `DotVoteRules`; `{"enabled": false}` turns it off. `dr_vote_after` is how many seconds into a course the ballot opens.
