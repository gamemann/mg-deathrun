# The round: sides, the end, credit, points, the vote

The second asymmetric game in the family and the first where **the hazards are another player's decisions**: nothing on a course moves until an activator presses its button, every trap kills, and nothing comes back (no respawn, no checkpoint). The skill on one side is getting through; on the other it is timing. Built from mg-wipeout's skeleton; where a comment says another game found something, the line was kept because it is still true here.

## The sides are drawn

Two fixed sides, `RUNNERS` (1) and `ACTIVATORS` (2). At the top of every round `DrGame._draw_sides` draws `config.activators_for(players)`: one per `players_per_activator` (8), at least one, at most `max_activators` (6), never everybody, **from everybody who was not an activator last round**, shuffled on the round's own seed. A rotation is fairer on paper and gamed in practice (leave and rejoin to move up it); a draw that repeats reads as favouritism. `activator_may_repeat` turns the exclusion off.

**A player may choose** (`allow_side_choice`): `!activator`, `!runner`, `!any` in chat, as module commands. The draw orders volunteers, then the undecided, then those who asked to run, who are drawn only when the round would otherwise have no activator, because it must have one.

A joiner mid-round is benched: watching, unhurtable, on no side. They cannot end a round by existing.

## A round is decided by the game

`DrRules` returns CUSTOM when `DrGame` has decided: every runner out, activators win; every activator out (including one who leaves), runners win; the clock, `timeout_winner` (activators by default). dot-match's own backstop is the countdown plus the round plus a minute.

## The end

The first runner across the finish is teleported into the end arena with a weapon from the pool and **calls every activator down** (`Phase.SHOWDOWN`): armed (`activator_weapon`, or the pool), at `activator_health_scale` (1.5) times health because it is one against several, everybody untouchable for `arrival_grace_seconds` on arrival. **The buttons stop**: a runner still on the course runs it with nobody pressing, the reward for the runner ahead. Every later finisher arrives armed the same way.

## Credit

A trapdoor kills nobody; the spikes under it do. `_watch_course` remembers the last running trap whose zone each runner was in (`_credit`), and a fall or a pit within `CREDIT_SECONDS` (4) is that trap's, credited to whoever pressed it (`pressed_by`) as dot-combat damage with them as attacker, so the kill feed, dot-match and `DrProgress.TRAP_KILLS` agree.

## Points and the Tab board

`winner_points` (10) to everybody on the winning side and `first_across_points` (5), replicated as `net_points` beside `net_ping` (dot-server's session ping), on dot-menu's scoreboard under Tab with the player's face, name, side, points, time and ping. The face is the figure's head rendered once per skin into a small SubViewport (`DrClient._portrait`; six skins cover everybody, a site avatar's choice included).

## Runners do not see the activators

`activators_seen` is off: a runner's client does not draw the activators behind the walls, except in the showdown.

## The course vote

A round here is a course, so dot-vote's ROUND_END trigger (open at a round's end, apply at the next) is one course late. `DrVote` uses MANUAL: a ballot opens `dr_vote_after` (20) seconds into every course and is applied at the round's end (`apply: END_OF_ROUND`), setting `DrGame.next_course_id`, which the next `_lay_out_course` uses once. A rocked vote also waits for the round's end (`rtv_apply`), because changing the floor mid-round kills everybody on it. No time limit (`duration_sec` 0), the current course is on the ballot, no cooldown (a server with two courses would otherwise offer nothing). Stand-ins do not vote, so a server of stand-ins never opens one. dot-vote's command set comes with it, and the client shell draws the ballot from the `map_ballot` notice. Under MANUAL the director hands every opening to its host, a passed rock-the-vote included, so `DrVote` opens one on `director.clock.expired` (reason `rtv`); without it `!rtv` answered "Rocked. 1 of 1." and nothing opened. `rtv_delay_sec` is 0: dot-vote's two minutes are longer than a course. The course list is refreshed in `_game_load` after the delivered courses arrive, as well as after `dr_reload`: built before them it held only the practice course, and a list of one never opens a ballot. `examples/dedicated` arms both (a module loaded with a pack named, and `rtv` at the console). An owner reshapes it in `user://cfg/deathrun_vote.json` or `game.yml`'s `metadata: course_vote:`, keyed as `DotVoteRules`; `{"enabled": false}` leaves the rotation alone. Not yet tried in a browser.

## Weapons and the figure in somebody's hand

Players are drawn as the family's animated people: `DrFigure` wraps dot-player-char's `DotHumanoidFigure` (the avatar's blocky atlas letter picks the person, `DotHumanoidLook.from_letter`; the side colour goes on the top; it is told the floor, the vertical speed and the crouch), with a `ZeeWorldModel` in the person's gun hand (a bone attachment, so it moves with the gun clips; a melee swing is the person's slash over the legs), read off the rig for a player this process simulates and off the snapshot's slot among the weapons the server announced (`DrPlayer.dealt`, from each `ARMED`) for a mirror. The reasoning is in [mg-smash-copter's client.md](../../mg-smash-copter/docs/client.md#figures-and-a-gun-in-somebody-elses-hand). The server sends the wanted slot on every tick (`weapon_command_for`), which relies on dot-weapon not restarting a switch on a repeated select.

**The bridge connects `player_armed` itself.** mg-wipeout wired it in the module, so the net suite, which has no module, never heard a weapon handed out.

## Colour and light

The family's sunny look (game-arena's built-in maps) with each course's theme kept and the traps the only saturated things on screen: moving parts are Kenney's orange, lethal parts and the spike plates Kenney's red, and nothing else competes with them.

- **Surfaces** are roles (`DrTextures`): the deck, walls and supports, starts and finishes, and the end arena all draw Kenney's light grid under a pastel (`INSTALLED_TINTS`: a hair-under-white deck, light lavender walls, mint safe ground, lavender arena), and the theme's `deck` colour multiplies the deck on top. A white deck clipped under the sun and lost the grid, which is how far a jump is; charcoal walls made every corridor a dark tunnel; Kenney's purple arena was a magenta floor. A spike plate in the walls' colour hid a spike wall in the wall it slides out of, so plates are the hazard red.
- **A surface skin** (theme `surface`, `DrTextures.skin`, set by `DrCourse.build` for the length of the build): a CC0 photograph set from `textures/surfaces/<name>/` (credits in its LICENSE.txt) replaces the grid on still decks and walls only, 4 m a tile with a one-metre checker composited over it; movers and hazards keep their colour tile so the traps stay the saturated things. The key is written into a normalised theme only when present, so no baked course's fingerprint moves.
- **Light is a dot-lighting document made from the course's theme** (`DrCourse.light_document`): the theme's sun colour, its sky at the zenith, its horizon as fog from 120 m, its void under the horizon; a warm high sun behind the start, so the faces a runner runs toward are lit; a pale cool fill whatever the theme; filmic and glow. The theme's old `fog` density is no longer read. A repaint never touches geometry or a course document.
- **Compatibility** (this game's and the shell's renderer) clips a sunlit pastel to white at Forward+'s numbers, so `DrCourse.light_profile()` is dot-lighting's `painted()` (API 3), which matches its light to the renderer, lowers the exposure, grades and adds a shadowless fill so shaded faces keep their edges. Shadows stay on in the browser. Check a look change in Forward+ too (`GODOT=<a wrapper that adds --rendering-method forward_plus> tools/shot.sh`).
- **A contact shade where still boxes meet** (`DrCourse._add_contact_shade`, dot-lighting's `DotContactShade`, API 4, by path behind `DotAddonApi.build_level`): soft bands at a wall's foot, a pillar's base, the walkway's step, which SSAO gives on Forward+ and Compatibility cannot. Only still, visible, opaque, unpitched `box` pieces: movers, turntables and every trap part move or flip lethal and the shade is one mesh built with the course, so it would stay where they were; ramps are tilted; the gate is see-through and drops. Rendered from the activator's walkway before and after.

## Cameras and bodies

Players pass through each other by default here (`mp_solidplayers 0`, dot-player-controller's rule; this game's pick, because a shove on a ledge is a death decided by who walked into whom, drawn in the past). The camera fade keeps a runner who walks through you out of the lens. An owner who sets 1 gets bodies: every player's motor mask has the player layer and each body a standing `SolidHull` (`DrGame._apply_body_mask`, again on every change). `mp_forceview` decides whether F5 may switch to third person (1 first only, 2 third only). Both bound REPLICATED by the module and followed through the link. The third-person camera is a dot-core `DotCameraBoom` swept from the eye with `CHASE_UP` added as `lift`, stopping against the course and props, never players; a `DotCameraFade` on the camera is handed every other player (`_other_players`) and hides one at the lens; dot-spectate is handed the level for its chase and death cameras. `tools/camera_check.sh` flies both cameras round every piece of the course (armed), walks the player into another with the rule on and off, and with `--render` draws both views and the walk-in before and after.

Whoever is out can fly a free camera (G): dot-spectate's `DotSpectatorRules`, one object on the game (`DrGame.spectate_rules`) shared with the manager, with `mp_forcecamera`, `mp_freeroam` and `mp_freeroam_speed` bound REPLICATED by the module and followed by the client. Roaming is on by default; `mp_forcecamera 1` or `2` (or `mp_freeroam 0`) refuses it, and a roamer is put back on a player if the operator tightens it mid-roam. The key is a `ROAM` request the server decides (a refusal returns as a notice), the `SPECTATE` view event carries ROAMING back, and the client flies a `DotSpectatorFreeCam` per frame, zeroing the dead body's movement command (online and offline, in `DrClient._stamp`). `dr_spectate_camera` stays as an alias that writes through `mp_forcecamera`.

## The HUD

`dr_hud.gd` draws the clock, health and the button prompt through dot-ui's glance pieces: `DotScoreStrip` with the clock alone (hidden between rounds, red for the last ten seconds) and the phase line under it, the course name under that; `DotVitals` only at the end, because a trap is a death and a number that never moves teaches a player to ignore it; `DotKeyPrompt` under the crosshair at a button, the trap's name with the use key drawn as a key, or "<trap> — spent" in the spent colour and no key. The use key is `DrClient.USE_KEY`, handed to the HUD, so the prompt, the phase line and the activator's shout name the key the client reads. Coloured by `DrHud.piece_theme()` (a slate-violet plate, the course name's pale blue as highlight). The health plate ends 206 pixels off the bottom, above the chat box's full eight-row log (202); the old number ended at 150, over it. `tools/shot.sh --view=button [--spent]` renders the prompt. Naming these classes makes the pack need a client shell with dot-ui API level 4; the derived `requires.json` asks for it and `headless_run` checks it.

## Settings

`DrSettings` is dot-menu's `DotMenuSettings` with this game's schema (sensitivity ACCOUNT at the family's 0.022 degrees per unit, field of view SERVER_CLAMPED with default 92, three volumes). Escape opens it; walking is suspended while it is up.

## Toys: loose ones only

A course's `toys` are a few of dot-props' loose toys (a ball in the start room, balls, barrels or a tyre in the end arena; `DrCourse._build_toys`, validated in `DrCourseDoc`). Never a fixed toy: a trampoline or a pad would be a way past a trap, and anything solid would be cover in the showdown. A runner walks through a loose toy and pushes it (`DrGame._advance_toys`); a trap's moving parts are the world, so a crusher or a trapdoor sends a ball flying; an armed runner's shot down the same ray pushes it and goes on to the combat (`_shoot_toys`, dot-props' `shot_along`), whose trace never sees a toy. The warmup's kicks are put home when the first round starts; a new course builds them fresh. Replicated as `net/dr_toy_net.gd` through TOYS after STAGE and to a joiner; a client registers every mirror the moment TOYS arrives and hands each its toy when its course is built, because dot-net stops reading a snapshot at the first entity a client does not know. `sv_toys*` are bound REPLICATED and followed. This game links dot-props for them (`.gitignore`).


**`cfg/game/mg-deathrun/dot_map/maps.yml` says which courses rotate** (dot-map's `DotMapRotationFile`, shipped in the game's `cfg/game/mg-deathrun/dot_map/`, replaced by the operator's `cfg/server/addons/dot_map/maps.yml`; `sv_map_rotation_file` names it, `dr_maps_reload` re-reads it, `dr_rotation <name>` switches). `DrCatalogue` holds documents, not `DotMapDef`s, so it keeps a mirror of the ids (built-in, directory, delivered pack and Workshop alike) for the file to mark `in_rotation` on. `rotating()` (the draw, the ballot, nominations) honours the mark; `playable_courses()` does not, so the map menu and an admin's change still load a course the file leaves out, and mark it "not in rotation". dot-vote's list source gets `in_rotation_fn` so the pack maps it merges are filtered too. A rotation in the file replaces `dr_shuffle_courses` (`cycle` follows the written order); `commands:` renames dot-vote's roles and `dr_courses`, `dr_reload`. The practice course drops out of a file's rotation unless it is all there is. `dedicated` section "rotation file".
