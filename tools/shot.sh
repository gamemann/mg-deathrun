#!/usr/bin/env bash
# Render the game and look at it. The check no assertion in this repository makes.
#
#   tools/shot.sh                                      # a runner's own eyes, a few seconds in
#   tools/shot.sh --view=course --dr-course-ids=dr_ice_works   # a course, from above
#   tools/shot.sh --view=start                         # the start, from behind the runners
#   tools/shot.sh --view=activator                     # the walkway, from the activator's eyes
#   tools/shot.sh --view=button [--spent]              # the activator at a button: the key prompt
#   tools/shot.sh --view=trap --trap=ice_jaws --after=0.5      # a trap, mid-run, on somebody
#   tools/shot.sh --view=trap --trap=t29 --eye=-7,2.5,-5  # ...from a camera 7 m behind, 2.5 up and 5 to the side of the victim (a corridor along +X)
#   tools/shot.sh --view=third --seconds=8             # third person, on the course
#   tools/shot.sh --view=cover                         # the loading cover, before it lifts
#   tools/shot.sh --view=end                           # the end arena, from a runner who made it
#   tools/shot.sh --view=killcam --seconds=2           # the round's last moment replayed (--seconds=7.5: the podium)
#   tools/shot.sh --view=end --end-wait=5              # ...once the weapon they were handed is out
#   tools/shot.sh --view=end --end-wait=3 --fire=0.4   # ...firing: flash, tracer, impact, the counter down
#   tools/shot.sh --view=third --no-bake               # without the baked light, to compare
#   tools/shot.sh --view=maps --seconds=0.5            # M: the solo course list with a Workshop fixture course (Name [Pack])
#   tools/shot.sh --view=third --board                 # with the Tab scoreboard held open
#   tools/shot.sh --view=course --out=res://screenshots/x.png  # any --dr-* is the game's config
#
# xvfb-run because this needs a rendering context and the machines this runs on have no
# display. `--headless` is NOT a substitute: it gives a null renderer and saves a frame of
# nothing, which is worse than no screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots

view="eyes"
seconds="4"
out=""
# A render wants the round running: no warmup and a short countdown, unless asked otherwise.
# Passed as the game's own flags, because the client reads its configuration as it loads and
# a value changed after that has already been copied into the round's rules.
config=("--dr-warmup-seconds=0" "--dr-countdown-seconds=1")

for arg in "$@"; do
    case "$arg" in
        --view=*)    view="${arg#*=}" ;;
        --seconds=*) seconds="${arg#*=}" ;;
        --out=*)     out="${arg#*=}" ;;
        --dr-*)      config+=("$arg") ;;
        --trap=*|--after=*|--eye=*|--end-wait=*|--fire=*|--board|--spent|--no-bake) config+=("$arg") ;;
        *)           echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

[ -n "$out" ] || out="res://screenshots/${view}.png"

scene="res://tools/shot.tscn"

exec xvfb-run -a "${GODOT:-godot}" --path . --resolution 1280x720 \
    "$scene" -- "--seconds=$seconds" "--view=$view" "--out=$out" "${config[@]}"
