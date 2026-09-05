class_name G2GRequest
extends DotNetMessage

## Anything a client asks the authority for. Reliable, rare, to the server only.
##
## Small on purpose: every one of these costs the server work, and the manager
## rate-limits them per peer — a client sending thousands is broken or hostile.

const NAME := &"g2g.request"
const KIND_BITS := 4
const MAX_BODY := 2048

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


static func of(p_kind: int, p_body: PackedByteArray) -> G2GRequest:
	var ask := G2GRequest.new()
	ask.kind = p_kind
	ask.body = p_body
	return ask


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= G2GEvents.Ask.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown request kind %d." % kind)
	return DotResult.success(true)


func reader() -> DotNetReader:
	return DotNetReader.new(body)
