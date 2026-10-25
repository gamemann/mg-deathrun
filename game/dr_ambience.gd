extends RefCounted

## What the courses' ambience is: the cvar defaults shared by the simulation (binds `dr_ambient*`) and the client's director (plays them).

const PREFIX := "dr"
## The trap sounds are the warning: the layer sits under them, with rare one-shots.
const LEVEL := 0.3
const RATE := 0.5
const DEFAULT_MOOD := &"industrial"

## By course id prefix; any course not listed takes the default.
const PREFIX_MOODS := {
	"dr_ice": &"snow_wind", "dr_temple": &"cave_tunnel", "dr_aztecan": &"cave_tunnel", "dr_ramesses": &"cave_tunnel",
	"dr_quarry": &"outdoor_night", "dr_horror": &"interior_horror", "dr_fogtown": &"swamp",
}


static func make_rules() -> DotAmbienceRules:
	var r := DotAmbienceRules.new()
	r.prefix = PREFIX
	r.volume = LEVEL
	r.frequency = RATE
	return r
