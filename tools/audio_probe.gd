extends Node

## Under xvfb-run (never --headless, whose audio driver is Dummy): does each machine make a
## noise? Bakes the bank as a client does and plays every trap sound beside the listener.
##   xvfb-run -a godot --path . res://tools/audio_probe.tscn

const DrAudio := preload("res://game/dr_audio.gd")


func _ready() -> void:
	var audio := DrAudio.new()
	add_child(audio)
	var ready_now := audio.setup()
	var sink := audio.manager.sink as DotAudioSinkGodot
	var ok := ready_now.ok and sink != null
	print("driver=%s sink=%s" % [AudioServer.get_driver_name(), sink != null])

	for id: StringName in [DrAudio.TRAP_SAW, DrAudio.TRAP_DROP, DrAudio.TRAP_CRUSH, DrAudio.TRAP_FIRE, DrAudio.TRAP_GRIND]:
		var stream: Variant = sink.bank.get(id) if sink != null else null
		var length := (stream as AudioStream).get_length() if stream is AudioStream else 0.0
		var voice := audio.manager.play_at(id, Vector3(0, 0, -3))
		await get_tree().process_frame
		print("%s baked=%.2f s voice=%d" % [id, length, voice])
		ok = ok and length > 0.3 and voice != 0

	get_tree().quit(0 if ok else 1)
