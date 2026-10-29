extends DotNetMessage

const DrEvents := preload("dr_events.gd")

## Anything a client asks the authority for. Reliable, rare, to the server only.
## Not a per-tick intent: those are BUTTONs, ordered against the movement they were made with.

const NAME := &"dr.request"
const KIND_BITS := 4
const MAX_BODY := 256

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## Built with `new(kind, body)` and not a self-preloading factory (leaks at exit on 4.7.2;
## docs/comment-notes.md). The registry decodes with a bare `new()`, so both arguments default.
func _init(p_kind: int = 0, p_body: PackedByteArray = PackedByteArray()) -> void:
	kind = p_kind
	body = p_body


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= DrEvents.Ask.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown request kind %d." % kind)

	return DotResult.success(true)


## Whether every [enum DrEvents.Ask] fits in [constant KIND_BITS]. What a check reads: the writer
## masks a value to its field, so a kind past it goes out as a smaller one and nothing errors.
static func fits() -> bool:
	return int(DrEvents.Ask.values().max()) < (1 << KIND_BITS)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "DrRequest(%s, %d bytes)" % [DrEvents.ask_name(kind), body.size()]
