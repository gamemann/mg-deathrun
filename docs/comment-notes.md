# Reasoning moved out of comments

Longer reasoning that used to sit above the code, kept here so the source carries only the short why.

## DrFigure (game/dr_figure.gd)

The game drew no person at all until 2026-09-24: every player's own view was first person and third person showed the platform, so nobody needed a body until a networked client drew other players as nothing. See `DrPlayer.present_body` for when one is shown.

The body is a top-level node placed by its caller every frame. The player node is the simulation's: on a remote player it is written by the interpolator once a frame, but on the local player and on every offline stand-in it moves once a tick, and a body hung off it would step at the tick rate while the camera beside it is blended between ticks. So `DrClient.present_frame` hands every body the position this frame draws (the node for a remote player, `render_state()` for one this process simulates) and nothing in the figure computes one.

The person is one of the family's (dot-player-char's `DotHumanoidFigure`, on the rig every game's players, bots and NPCs share). Which person a player is comes from the blocky kit's atlas their avatar names (`ATLASES`): the atlas letter is a look (`DotHumanoidLook.from_letter`), so every avatar document written before the people arrived dresses the same person on every client. The side is on the torso (`TEAM_TINT`), because the first thing to read off a body is whose side it is on. The weapon is in the person's own hand (`DotHumanoidFigure.attachment`), so it moves with the gun clips and a melee swing; the legs keep walking under a swing because the figure plays it on the upper body only.

`hold` is asked every frame and is cheap when nothing changed: the model is only re-equipped when the id differs from what is drawn.

## DrBindings (game/dr_bindings.gd)

The table exists because four things read it: the client matches events against the actions, the settings document stores one binding per row, the menu's Controls page draws a key per row, and the help screen (H) and the HUD's prompts name the key each is on. Until 2026-10-11 these were keycodes in `DrClient._unhandled_input`. Walk is Shift, for a narrow ledge: dot-player-controller's own walk action, so the sampler reads this row. The chat keys are dot-game's chat window's own actions. H is help in every game of the family (dot-menu adds the row), so nothing here may default to it.

## DrSettings (game/dr_settings.gd)

This is dot-menu's `DotMenuSettings` with this game's schema (2026-10-09). It replaced a 250-line copy of mg-wipeout's file that was also in five other games; what is left is where the document lives and the stock keys it has nothing to apply to. The scopes are the family's: `sensitivity` is ACCOUNT under the shared `tmc_account` namespace (a person's hand, the same in every game), `field_of_view` is SERVER_CLAMPED (a wide view is an advantage a server may cap, and dot-settings gives a server no way to read it), the volumes are this machine's.

## DrRules (game/dr_rules.gd)

dot-match's elimination rule nearly fits, and nearly is the problem. It ends a round when a side has nobody alive, but a runner who joined mid-round is benched rather than dead, an activator called to the end is alive in a different place, and the clock's winner is a server setting. What decides is `DrGame`, and `DotMatchRules` is the documented place for a mode dot-match does not ship. The answer is read, never computed here: this rule is a pure function of what the game decided, and a game that has not decided returns NONE every tick.

The `time_limit_sec` is a backstop set by `DrGame` to the countdown, the round and a minute more. A round the game somehow never decided ends on it as a draw rather than running for ever, and dot-match stops warning at every boot that nothing but a custom outcome can end a round.

## DrController (game/dr_controller.gd)

The two hooks must run inside the tick, and outside it is wrong in a way only a connected client shows. dot-net's predictor re-simulates past ticks when a snapshot corrects the client by calling `simulate_tick` directly, so anything a game does around the tick in its own loop is skipped on every replayed one. A replay that did not pose the obstacles at the tick being replayed would sweep the player against a trapdoor where it is now, several ticks later, and every correction would correct into a different answer. dot-player-controller documents `_on_pre_simulate` and `_on_post_simulate` as running during replays for exactly this.

## DrEvent and DrRequest (game/net/)

Both are built with `new(kind, body)` and do not preload themselves. They used to, for a typed `static func of()` factory. A script that extends `DotNetMessage` and preloads itself, first loaded from a module a running `DotServer` loads at runtime (how every deployed server loads this game), leaks the whole script graph at exit on Godot 4.7.2. Measured in mg-buses-from-hell (8ed866c) with a two-line reproduction. The registry decodes with a bare `new()`, which is why both arguments default.

There are three requests and none is a per-tick intent. Firing and pressing a trap's button are BUTTONs, because they must be ordered against the movement they were made with; requests are the once-only kind ("my world exists, start telling me about yours", "I want to watch somebody else") that must not be lost.

## DrToyNet (game/net/dr_toy_net.gd)

The toy is the server's physics, never predicted, because Godot's rigid-body solver is not the same on two machines. The client's toy is frozen and posed from the wire (`DotPropToy.show_state`), so a see-saw a person stands on is the plank the server tipped, an interpolation behind. Toys are paired by index: both ends build the same toys in the same order from the map, so the TOYS event carries only net ids in toy order. A use count rather than a use event: a honk, a switch and a bounce each move `net_count` by one (eight bits, it wraps) and a client plays the sound when it sees it move, so a joiner and a lost packet cost nothing but a late sound. game-hide-n-seek, game-playground and game-arena carry the same file.

## DrNetCommand (game/net/dr_net_command.gd)

The three game buttons ride in `DotFpsCommand.buttons` for the reason a jump does: they are per-tick, held rather than pressed once, and must be ordered against the movement they were aimed with. A shot sent as a reliable request would arrive a round trip later and be resolved against a position the player has already left. The slot is a field of its own because `DotFpsCommand` has eight buttons and no room for a number (see `DrPlayer.wanted_slot`).

`use` lives in this game's message and not in `DotFpsCommand`, whose spare buttons are taken; widening the movement command would break every game in the family for a key only this one has. It is held every tick and the server turns it into an edge (`DrGame._advance_buttons`), because a press sent as a reliable request would land a round trip after the key, against a runner who has left the trap. mg-wipeout's grab key works the same way.

## DrHud (game/dr_hud.gd)

The activator's list of traps is the number they cannot read off the world: a button's cap goes red when its trap is spent, but the activator is watching the runners, so a list down the side says what is left without a turn of the head and the line in the middle says which button E would press right now. Health shows only at the end: nothing on a course hurts a little, a trap is a death, so a health number would never move. The menu hook (`_menu`) came from the first play test (2026-10-11), which asked for a darker HUD a player can restyle in the menu; it is duck-typed and called by name for a client shell older than dot-menu 7.

## DrPaths (game/dr_paths.gd)

A delivered pack does not mount at the path its content was authored at: it mounts at `res://dot_cloud/<id>/<version>/`, so every absolute `res://` reference to the game's own files resolves against the host project instead. A script knows where it is (`resource_path` is the mounted path), so the game root is this script's directory with `game/` taken off. Anything holding one of these paths is a `static var`, not a `const`, because a constant is folded at parse time and `root()` is not knowable then.

`root()` goes through a `Resource` local because a const-preloaded script is typed as its own class and `resource_path` is not reachable on that ("Cannot find member resource_path in base res://...").

`rebase_onto` exists so the mounted case can be tested from a build. Built in, `root()` is `res://` and every `res://` path is already under it, so each property of `rebase` that matters only in a pack is a tautology and a suite asserting them passes whatever the body says (breaking the idempotence and re-running gave 101 passed, 0 failed).

`rebase_onto` must be idempotent. The publisher rewrites every `res://` string inside a `.tscn`, `.tres` and `.import` onto the mount prefix before signing, and does not rewrite those inside a `.gd`. A game therefore has both kinds: a script `const` that says `res://props/x.tscn` and needs rebasing, and an exported property the publisher already turned into `res://dot_cloud/<id>/<version>/props/x.tscn`. Rebasing the second doubles the prefix into a path that fails to load and is easy to misread. This is the seventh form of the family's one delivery bug; the other six are in dot-server-deploy's docs/delivery-constraint.md.

## Tools

`tools/shot.sh` views: no argument (a runner's own eyes, a few seconds in), `--view=course` (from above, with `--dr-course-ids=`), `start` (from behind the runners), `activator` (the walkway), `button` (the key prompt; `--spent` once the trap is spent), `trap` (`--trap=ice_jaws --after=0.5`), `third`, `cover` (the loading cover before it lifts), `end` (the end arena), `killcam` (`--seconds=2`, or `7.5` for the podium). Any `--dr-*` is the game's own configuration (see `DrConfig`), because `DrClient` reads it.

`tools/camera_check.sh` checks, in the real offline game, the cameras and bodies the first play test caught: the third-person and spectator chase cameras flown round the start and every checkpoint (dot-core's `DotCameraCheck`), never inside, armed by the unprotected camera being in or behind the course on some frames; and the player walked into another player held still, where `mp_solidplayers 1` keeps the capsules apart and 0 lets them overlap (the armed half). `--render` adds the eye views before and after, in `screenshots/cameras/`. The walk is deterministic: the other player is put back on its spot every frame so its own brain cannot steer away, and the walk is one the pass-through run proved clear.

`tools/lightmap_scenes.gd` writes one bake scene per course for dot-lighting's baker, run by `tools/bake_lightmaps.sh`. It needs a display, not `--headless`, because a headless process keeps no mesh or image data to save. Only pieces `DrCourse.is_bakeable` calls still and opaque are baked; movers, turntables, trap parts, the gate, lethal pieces and buttons stay dynamic and are lit live, with the generated probes giving them the bounce, so nothing bakes a shadow from a part that is not there a second later. The sun gives only its bounce (BAKE_DYNAMIC) because its shadows are how a runner reads where a trap is; dot-lighting's fill is BAKE_DISABLED, being already "more sky". A course has no lamps. Changing any of that changes what a bake means: bump `DrCourse.BAKE_VERSION`.

`tools/render_cover.gd` runs a dedicated server in a second process (the scene with `--role server`); both halves share the root name because an RPC path is the name. `tools/load_probe.gd` needs xvfb-run, never `--headless`.
