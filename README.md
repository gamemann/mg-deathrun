This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game, most players are **runners** racing down a long course full of traps, while one or more **activators** stand beside it with a button for every trap and try to kill them. Whoever makes it to the end gets a weapon and fights the activators. This is inspired by the classic deathrun minigame maps!

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## How it plays
Everybody starts at once: the runners behind the start gate, the activators at the start of a walkway that runs beside the course. When the gate drops:

- **Runners** run. A trap does nothing until somebody presses its button, so the danger is the activator: watch them, bait a trap, wait for it to be used up, then go. If a trap gets you, you watch the rest of the round.
- **Activators** walk along their walkway and press **E** at a button while somebody is in that trap: trapdoors, closing spike walls, a crusher, a rolling log, sinking ice, saws and fire. Most traps work once a round. The list on the right of the screen shows which are left.
- **The end.** The first runner across the finish gets a weapon in the end arena, and the activators are called down to fight them (armed, and a little tougher, since it's one against several). Anybody who makes it after them arrives armed too.

The runners win if every activator is killed or leaves. The activators win if every runner is caught, or if the clock runs out. A new set of activators is drawn each round, one for every eight players by default, from people who weren't one last round. Some stretches of the courses are bunny-hop jumps.

Partway through each course, players vote for the next one (`!vote 2`, `!rtv`, `!nominate dr_foundry`).

There are three courses: a short practice run built into the game, and **Ice Works** and **The Foundry** from [mg-deathrun-maps](https://github.com/gamemann/mg-deathrun-maps).

## Controls

| Key | Action |
| --- | --- |
| **WASD** / mouse | Run and look |
| **Space** | Jump |
| **Shift** | Walk (for a narrow ledge) |
| **Ctrl** | Crouch |
| **E** | Press the button in front of you (activators) |
| **Mouse 1** | Fire, at the end |
| **Mouse 2** / **R** / **1**-**5** | Alt-fire / reload / weapon slots |
| **F5** | First or third person |

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The game is built from many Dot addons, each in its own repository, so the easiest way to get everything is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap). It clones every project and links the addons into each one:

```bash
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/mg-deathrun
./game.sh
```

On Windows, run `bootstrap.ps1` instead and open the project in Godot.

The courses come from the mg-deathrun-maps checkout, which bootstrap links into `courses/` for you.

`game.sh` does everything else:

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline against bots (one of them works the traps when you run, and they run when you are the activator) |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh shot` | Save a screenshot to `screenshots/`. `./game.sh shot --help` lists the views |
| `./game.sh help` | All of the options |

`online` and `server` use [dot-server-deploy](https://github.com/modcommunity/dot-server-deploy), which bootstrap clones next to this one. Run its `./setup.sh` once first.

## Running a server
Settings are cvars. Set them in the server's config, on the command line, or live from the console. Most of them take effect from the next round.

```
dr_round_seconds 300           // the longest a round runs (a course may ask for less)
dr_players_per_activator 8     // one activator for every this many players
dr_max_activators 6            // never more than this many
dr_activator_repeat 0          // 1 = last round's activator may be drawn again
dr_timeout_winner 2            // who wins when the clock runs out: 0 draw, 1 runners, 2 activators
dr_activator_health 1.5        // how much tougher activators are at the end
dr_autobhop 0                  // 1 = hold jump to keep hopping
dr_bot_trap_delay 0.25         // how late bot activators press, in seconds
dr_min_players 3               // fill the round with bots up to this
dr_bots 1                      // 0 = no bots
dr_vote_after 20               // seconds into a course before the vote for the next one opens
```

`--dr-course-ids=<ids>` limits a server to some courses. The vote's settings go in `user://cfg/deathrun_vote.json` (`{"enabled": false}` turns it off); dot-vote's README lists them.

Console commands:

| Command | |
| --- | --- |
| `dr_status` | What the server is doing |
| `dr_courses` | The courses the server has, and any it refused (with the reason) |
| `dr_traps` | This course's traps, and which are used up |
| `dr_reload` | Read the course folder again, for the next round |
| `dr_net` | What the network code is doing |

### Admin commands
These come from [dot-moderation](https://github.com/modcommunity/dot-moderation): `noclip`, `freeze`, `speed`, `gravity`, `god`, `buddha`, `hp`, `slay`, `slap`, `rename`, the teleports, `blind` and `beacon`. `respawn` puts somebody back at the start of their side. `give` and `strip` are turned off, because the weapons are what the end hands out.

## Writing a course
A course is a JSON file: a start, a corridor of pieces and traps, a walkway with a button for every trap, a finish and an end arena. The courses are in [mg-deathrun-maps](https://github.com/gamemann/mg-deathrun-maps), whose `tools/build_courses.py` writes them section by section (so the corridor and the walkway always line up). That is also the easiest way to write a new one. [`courses/README.md`](courses/README.md) describes the format. The server sends the course to each player when the round starts, so players don't need the course files.

## Testing

```bash
./game.sh test                      # every script parses, then every suite runs
./game.sh test headless_courses     # one suite
```

| Suite | What it covers |
| --- | --- |
| `headless_run` | The game itself: sides, traps, deaths, the end fight |
| `headless_courses` | Every course: a bot runs it, every trap is sprung on somebody, every button is reached |
| `headless_net` | A server and a client in one process, over the network code |
| `dedicated` | A real server: boots, loads the game, runs its commands |

[`CLAUDE.md`](CLAUDE.md) has the design decisions and the reasoning behind them.

## Not done yet
- Traps give no warning before they go off.
- Every trap makes the same sound.
- The bots are simple: a bot runner follows the course and ignores the activator, and a bot activator presses the trap the nearest runner is in.
- There is no settings menu.

## Credits
Every surface is Kenney's Prototype Textures, tinted per course, and the players are Kenney's Blocky Characters ([kenney.nl](https://kenney.nl), CC0). The weapons are from [zee-dot-weapons](https://github.com/gamemann/zee-dot-weapons). Spikes, blades, fire and pools are drawn in code. Each kit's licence is next to its files.

## License
MIT. See [LICENSE](LICENSE). The Kenney art is CC0, which is public domain.
