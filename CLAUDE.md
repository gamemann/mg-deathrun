# mg-deathrun

One long course of traps. Most players run it; one or more activators, drawn fresh each round, stand on a walkway beside it with a button for every trap. Whoever reaches the end is handed a weapon, and the first one there calls the activators down to settle it. The second asymmetric game in the family, built from mg-wipeout's skeleton: a trap is a pure function of the tick and the tick its button went on, so a press is one event and prediction carries a runner exactly as the server does.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to this game. The courses are in `courses/`, a link to [mg-deathrun-maps](../mg-deathrun-maps), written by its `tools/build_courses.py`; `courses/README.md` is the format. **The detail is in [docs/](docs/README.md).**

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/traps.md](docs/traps.md) | touching `dr_course.gd` or `dr_course_doc.gd`, a trap, the tell, trap sounds, how a course reaches a server |
| [docs/design.md](docs/design.md) | the draw, how a round ends, the end arena, credit, points, the vote, weapons, settings |
| [docs/bots.md](docs/bots.md) | stand-in runners or activators |
| [docs/testing.md](docs/testing.md) | adding a check, believing a green run, rendering |
| [docs/history.md](docs/history.md) | a bug that "cannot be happening" |

## Layout

| Path | What |
| --- | --- |
| `game/dr_course.gd` | THE FILE: a document built; every trap a function of the tick and its press; `lethal_at`, the carry, the tell's flash |
| `game/dr_course_doc.gd`, `dr_catalogue.gd` | what a course is (pieces, traps as parts on a timeline, places), validated; every document the server has, the built-in practice course, what is next |
| `game/dr_game.gd`, `dr_rules.gd` | the simulation: the draw, buttons, deaths, the end, both kinds of bot; a `DotMatchRules` whose outcome is whatever `DrGame` decided |
| `game/dr_player.gd`, `dr_controller.gd` | one person (movement, the carry, side, hands); `DotFpsController` with the pre/post-simulate hooks the course needs |
| `game/dr_config.gd`, `dr_paths.gd` | every rule a course is played under; `rebase` for pack delivery |
| `game/dr_module.gd`, `dr_services.gd`, `dr_vote.gd`, `dr_server.gd` | the `DotGameModule` (cvars, `dr_status`/`dr_courses`/`dr_traps`/`dr_reload`, stand-ins, delivered courses); chat/voice/moderation; the course vote over dot-vote |
| `game/net/` | the codec (STAGE, TEAM, TRAP, FINISHED…), link, player behaviour, bridge |
| `game/dr_client.gd`, `dr_hud.gd`, `dr_audio.gd`, `dr_figure.gd`, `dr_settings.gd`, … | the client: poses the course per frame; its platform wiring (loading cover, settings, console, Tab, M, pointer, input block) is dot-game's `DotGameClient` (`platform`) |
| `courses/` | link to `../mg-deathrun-maps/courses` |
| `examples/` | `headless_run`, `headless_workshop`, `headless_courses`, `headless_net`, `dedicated` |
| `tools/` | `soak.tscn` (`./game.sh soak`, [docs/soak.md](docs/soak.md)), `shot.sh` (render a view), `trace_run` (where a stand-in runner goes), `audio_probe` |

## Running and testing

- `./game.sh` plays offline; `./game.sh online` runs a local server and browser client; `./game.sh test` parses and runs the five suites. `../mg-deathrun-maps/tools/build_courses.py --check` after any course change.
- `headless_courses` springs every trap on its `victim` spot and stands a runner on every `spared` spot. Run it after touching traps, the carry or the builder. [testing](docs/testing.md)
- **Render after touching what anyone sees**: the activator's view, trap colours and the end arena were only found by a picture (`tools/shot.sh --view=activator|trap|third --board|end`).
- After touching a camera, the view key or player collision: `tools/camera_check.sh` (cameras round every piece, armed; `mp_solidplayers` both ways; `--render` for frames). [design](docs/design.md#cameras-and-bodies)

## Rules

**Traps** ([traps](docs/traps.md))
- **Offline, the client's buttons go onto the world's own sample** (`DrPlayer.command_stamp`, set in `DrClient._adopt`), never onto `controller.current_command`, which `DrPlayer.simulate` samples over: that way no trigger ever reached the world's gun offline. `headless_run`'s "offline, the client's trigger" is armed ([history](docs/history.md)).
- **Every key is a `DrBindings` row read through its action**, never a keycode (Escape excepted); the HUD names the use key as bound (`DrHud.use_label`). H is help (dot-menu's stock key; `DrSettings._fill_help`), so no row may default to H. `headless_run` checks it and the Escape menu's Help and Leave.
- **M is the course list** (dot-menu's map menu): `DrGame.course_rows()` and `change_course_now()` (the next course plus dot-match's `begin_round_now`) serve both solo and the server, where dot-vote's map menu lets the owner's `sv_map_menu_flag` change it now and gives anybody else a vote. No row may default to M; `headless_run` and `dedicated` check it.
- **Every course has a bed and a ground** (`DrAudio.COURSE_SOUND`, or `ambience`/`surface` in its document); everybody on it steps through dot-audio's `DotAudioFootsteps`. Levels are measured with `addons/dot_audio/tools/loudness.sh` (−17 LUFS band; `loudness_trim_db` in `DrAudio.setup`), never set by ear.
- The only thing about a trap that travels is `TRAP` (index, the PRESS's tick). Never start a trap's clock on arrival.
- Lethal parts are measured (`lethal_at`), never collided; solid moving parts carry by exact displacement inside the player's tick. A death is the server's, sent as an event, never predicted.
- Moving parts are static bodies teleported through the physics server, never kinematic (a step late) or rigid; `headless_courses` relies on that to skip physics frames.
- A trap is parts on a timeline (`move | turn | spin`, `solid`, `lethal`), never a new kind. A new effect is a new part property, handled once in validator, builder, death test and carry.
- The tell is written into the document by `DrGame.with_tell`, in `_lay_out_course` only, so it is never added twice and clients predict it exactly. Its flash is drawn only, never moved.
- Only moving parts (orange) and lethal parts (red) keep a colour tile; every other role is the light grid under a pastel (`DrTextures.INSTALLED_TINTS`). The light is a dot-lighting document from the course theme (`DrCourse.light_document`), turned down under Compatibility; still boxes get dot-lighting's `DotContactShade` (`_add_contact_shade`, never a moving or trap part). [design](docs/design.md#colour-and-light)
- **Baked light** (dot-lighting's `DotLightBake`): `lightmaps/<id>.res`, one per course (the practice course and the five in mg-deathrun-maps), is tracked and ships in THIS pack, found through `DrPaths.rebase` (`DrCourse._attach_bake`). Only still, opaque `box`/`ramp` pieces are baked (`DrCourse.is_bakeable`): each has UV2 from `DotLightmapSheet` and the mesh path `<kind>_<n>/Mesh`; movers, turntables, every trap part, the gate, balls, cylinders, the lethal pieces and the contact shade stay live. The sun stays live (its shadows are how a trap is read) and gives only its bounce; a course has no lamps. A bake whose fingerprint (`light_fingerprint`: the still pieces, the theme, `BAKE_VERSION`) is not the document's is refused with a WARN and the course is drawn live; a server never loads one. **Edit a still piece or the theme, then rebake**: `tools/bake_lightmaps.sh [ids]` (the GPU box through `../gpu.sh`; run `../gpu.sh run mg-deathrun --import` there once first, or the scene tool hangs) and commit `lightmaps/`; `headless_courses`' "baked light" section fails on a stale bake. `dr_sections` bakes at `texel_scale` 0.5. `tools/shot.sh --no-bake` renders the live look to compare.
- The start gate is see-through (`DrCourse.gate_material`): the front row faces it from 1.4 m for all of warmup, and opaque it filled the screen and read as a spawn facing a wall. Starts face the way ahead (the second route point when a course has a route, else the finish); `headless_courses` checks both.
- One document is the whole map (both corridors, the end arena). Buttons at least 2.6 m apart; the walkway straight; the runners' wall no higher than the walkway on the activator's side; trap floors drawn as floor.
- Courses live in mg-deathrun-maps and reach servers through the owner's map config; `_add_delivered_courses` runs at load and after every `dr_reload`. The game's own pack carries only `dr_practice`.

**The round** ([design](docs/design.md))
- The draw excludes last round's activators (unless `activator_may_repeat`), shuffles on the round's seed, honours side choice, and never leaves a round without an activator.
- `DrRules` returns CUSTOM once `DrGame` decides; a mid-round joiner is benched on no side.
- At the end the buttons stop. Trap kills are credited to whoever pressed (`_credit`, `CREDIT_SECONDS`).
- The vote applies at a round's end (MANUAL trigger, `END_OF_ROUND`), rocked votes too: changing the floor mid-round kills everybody on it. The match answers dot-vote's `round_in_progress_fn` (`world.match_node.is_live()`, set by name because an older shell's dot-vote lacks it), so a `time_up: finish_round` limit that runs out in warmup or between rounds changes at once instead of holding for `finish_round_max_sec`; `dedicated` checks both halves.
- Under MANUAL `DrVote` opens a passed rock-the-vote itself (dot-vote does not), and `_game_load` refreshes the course list after the delivered courses: without either, `!rtv` or a delivered server never gets a ballot. [design](docs/design.md#the-course-vote)
- **A seat behind its client's loading cover cannot be hurt, and is the last drawn as an activator** (dot-game's "still loading"): `DrGame.harm_gate`, set by the module from `can_peer_be_harmed`, is asked in the combat resolver's `adjust` (every trap kill, fall and shot passes it; an admin's slay or slap carries `context.admin` and passes) and by `_draw_sides`. Bots and offline are never loading. `dedicated` checks it over a real ENet client (armed); `tools/render_cover.sh` renders the cover and the frame after it lifts. The bridge frees its link on exit, or a module loaded again opened a second one named `@Node@…` and every RPC to the client was lost.
- The bridge connects `player_armed` itself; never only in the module.
- **A READY before the player is seated is kept** (`_ready_unseated` in the bridge) and answered by `add_player`: over ENet with loss it overtakes the link's `loaded`, and a dropped READY left the client waiting for ever. `headless_net` sends it first (armed). [history](docs/history.md)
- A dead body falls as dot-player-char's ragdoll: the server picks the fall (`DrGame.decide_death`, on `player.death`), it rides DEATH last and optional, and the client copies it from the figure (`DrClient._fall`). `sv_ragdoll*` cvars bound in the module, REPLICATED, followed by the client. See dot-player-char's [docs/ragdolls.md](../dot-player-char/docs/ragdolls.md).
- **A round ends on its last moment** (`DrKillcam`, `game/dr_killcam.gd`): every drawn frame goes into dot-replay's `DotKillcamBuffer`, each death and finish is noted, and `round_over` replays the last one from its subject's eyes (a trap death from the victim's, a shot from the shooter's, a finish from the runner's) before dot-ui's `DotWinnerReveal` (top three by points) and the Tab board. `mp_killcam_time` (REPLICATED, 7, 0 off) is added to the intermission on the server (`DrGame.apply_intermission`, not when the intermission is 0, as in the suites); the setting `reduce_motion` shows the reveal's last frame at once. `tools/shot.sh --view=killcam --seconds=2|7.5` renders both.
- Runners do not see activators (`activators_seen` off) except in the showdown.
- A course's toys are loose only (dot-props, `toys` in the document): pushed by a walk or a trap, shot along the ray without stopping the shot; a client registers every toy mirror on TOYS before its course is built. [design](docs/design.md#toys-loose-ones-only)
- A round rebuilds the course inside the netcode's own tick, so `DrToyNet.pull` skips a toy out of the tree (dot-net history #30 skips the unregistered entity too); `headless_net` fails on any engine error in its stderr. [testing](docs/testing.md)

**HUD**
- **The drawn gun is only what the server armed** (`DrClient._give_locally` per `player_armed`/ARMED, never `give_everything`, which left a slot holding whatever was given last), counted by dot-ui's `DotAmmoCounter` bottom right (`DrHud._draw_ammo`), and brought to the server's count after `DRAWN_SETTLE_SEC` quiet (`DrClient.correct_drawn`: owner-only snapshot fields online, the world's rig offline). `headless_run`'s "an armed runner draws the server's gun" is armed.
- **A hit is the server's word** (`DrGame.hit_landed` from each weapon shot's damages, sent as HIT to the shooter alone; `headless_net` checks the routing, armed): dot-ui's `DotHitMarker` and zee's red burst on the body (`ZeeShotFx.play_body_hit`, by `has_method`). `tools/shot.sh --view=end --fire=N` renders a runner firing.
- The HUD follows the menu's theme and HUD size (`DrHud.follow_menu`, dot-menu's `follow_hud` by name); `DrHud.piece_theme()` is the accent only (the course blue, the ready green), never plate, text or ink, and the HUD's Labels set no colour of their own except the accent lines. `headless_run` checks a theme change reaches the pieces and the lines.

**Delivery**
- No `class_name`; every own `res://` path through `DrPaths.rebase()` where defined; see [mg-buses-from-hell's delivery.md](../mg-buses-from-hell/docs/delivery.md) and [mg-smash-copter's](../mg-smash-copter/docs/delivery.md) for why.
- dot-server-deploy's `examples/deathrun_client` is the real-client check against a delivered pack.

**Tests** ([testing](docs/testing.md))
- Every suite counts sections and checks. Read death events, not a later state; keep checks around a round boundary synchronous.

**Project settings**
- `project.godot` carries no comments: the editor drops them, and any key left at its default, the first time it saves the file, so the reasons for its settings live here. Gravity stays the engine default and nothing reads it: `DrConfig.gravity` is written onto the world's own physics space, because a project setting does not travel inside a delivered pack. The renderer is `gl_compatibility`, what the delivered client runs, and lighting is tuned under it. The canvas texture filter is Nearest so the prototype grid reads as discrete squares at the distance a runner judges the next gap from. Texture imports keep `detect_3d/compress_to=0` (`[importer_defaults]` starts new ones that way) so the editor never re-imports one VRAM-compressed on a first open.

## Not yet done

The Workshop's limits are in [docs/not-yet.md](docs/not-yet.md): a pack course is a course document, solo only, with no art or sound of its own.

The course vote has not been tried in a browser.

**Course documents may carry a `walkway` (2026-10-20)** for converted maps whose activators must wind through rooms: `DrCourseDoc` reads it (cap `MAX_PIECES` 2400 pieces), `DrCourse.walkway()` / `walkway_stop()` / `route_progress()` expose it, and `DrGame.bot_walk_toward` walks it; see docs/bots.md.
