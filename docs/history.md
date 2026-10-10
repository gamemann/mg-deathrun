# History

Kept because each could come back. Every one was found by running or rendering; none errored.

- **A round ended under the test that was measuring it.** The one runner caught by a falling block ended the round, intermission was zero, and the next round stood them back up, so "is the rider dead" read false about a rider who had died. Checks read death events now.
- **A stand-in jumped backwards, fell short, sailed past a block and missed a floe sideways**: the four rules in [bots.md](bots.md).
- **The weapon handout reached nobody without the module**, because the wiring was copied from a game that did it in the module. The bridge connects `player_armed` itself.
- **The activator could not see the near half of the corridor, trap floors were painted as traps, snowmen were green, and the end arena was magenta under a warm sun**: all four found by rendering, none by a check.
- **`dr_reload` dropped every delivered course**, because `load_from` forgets everything; `_add_delivered_courses` runs again after it.
- **The first swinging blade's geometry was wrong**, found the first time `headless_courses` stood a runner on its `spared` spot.
- **Nobody's weapon switch ever finished (cross-repo).** Rendering the end showed a runner holding the first slot under "You were handed a marksman", for good: the client and server send the wanted slot every tick and dot-weapon's `select()` restarted the switch on each repeat, moving the holster's deadline a tick further every tick. Fixed in dot-weapon, where it was every game's.
