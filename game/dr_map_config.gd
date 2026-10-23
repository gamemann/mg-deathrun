extends RefCounted

## The rules a course's file may set (dot-game's DotGameMapConfig); nothing a round has already decided.
const KEYS := {
	"dr_round_seconds": {"type": "int", "min": 30, "max": 1800},
	"dr_countdown_seconds": {"type": "int", "min": 0, "max": 60},
	"dr_players_per_activator": {"type": "int", "min": 1, "max": 64},
	"dr_max_activators": {"type": "int", "min": 1, "max": 16},
	"dr_activator_health": {"type": "float", "min": 0.5, "max": 10.0},
	"dr_gravity": {"type": "float", "min": 1.0, "max": 60.0},
	"dr_autobhop": {"type": "bool"},
}

## The keys a client predicts with, which it holds in its own DrConfig.
const CLIENT_KEYS := ["dr_gravity", "dr_autobhop"]
const GAME := "mg-deathrun"


static func client_keys() -> Dictionary:
	var out := {}
	for k: String in CLIENT_KEYS:
		out[k] = KEYS[k]
	return out
