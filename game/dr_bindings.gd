extends RefCounted

## Every key this game reads, as one dot-menu [DotMenuBindings] table: the action, the setting
## that stores it, the words a player sees, the default, and the card it goes on.
## Why a table, and the Shift/H/chat rows: docs/comment-notes.md.

const USE := &"dr_use"
const RELOAD := &"dr_reload"
const VIEW := &"dr_view"
## The spectator's free camera, on and off (`mp_freeroam`). Its flying keys are the movement keys.
const ROAM := &"dr_roam"
const SCOREBOARD := &"dr_scoreboard"
## dot-ui's chat window's actions, which dot-game's chat client leaves at their defaults.
const CHAT := &"chat_open"
const CHAT_TEAM := &"chat_open_team"
## Slots 1 to 5, the weapon pack's, at the end.
const SLOTS: Array[StringName] = [&"dr_slot_1", &"dr_slot_2", &"dr_slot_3", &"dr_slot_4", &"dr_slot_5"]


static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	keys.add_movement("Movement", "Ctrl", "Crouch")
	keys.add(&"dot_fps_walk", &"bind_walk", "Walk, for a narrow ledge", "Shift", "Movement")
	keys.add(USE, &"bind_use", "Press the button in front of you (activators)", "E", "Hands")
	keys.add(RELOAD, &"bind_reload", "Reload (at the end)", "R", "Hands")
	for i in range(SLOTS.size()):
		keys.add(SLOTS[i], StringName("bind_slot_%d" % (i + 1)), "Weapon slot %d (at the end)" % (i + 1), str(i + 1), "Hands")
	# The wheel goes through the weapons (and so does not jump: add_movement leaves the wheel's
	# jump rows off). Its own rows, rebindable on the Controls page.
	keys.add_wheel_weapons()
	keys.add(CHAT, &"bind_chat", "Chat", "Y", "Communication")
	keys.add(CHAT_TEAM, &"bind_chat_team", "Chat to your side", "U", "Communication")
	keys.add(VIEW, &"bind_view", "First or third person", "F5", "General")
	keys.add(ROAM, &"bind_roam", "Free camera while out (move keys fly, Sprint fast, Walk slow)", "G", "General")
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "General")
	return keys
