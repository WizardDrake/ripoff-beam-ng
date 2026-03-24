extends RefCounted
class_name W4Utils

## Internal class used internally to generate v4 UUIDs.
class UUIDGenerator extends RefCounted:
	var crypto := Crypto.new()
	var rng := RandomNumberGenerator.new()

	func generate_v4() -> String:
		var b := PackedByteArray()
		if crypto == null:
			b.resize(16)
			for i in range(16):
				b[i] = rng.randi() % 256
		else:
			b = crypto.generate_random_bytes(16)
		b[6] = (b[6] & 0x0f) | 0x40
		b[8] = (b[8] & 0x3f) | 0x80
		return "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x" % [
			b[0], b[1], b[2], b[3],
			b[4], b[5],
			b[6], b[7],
			b[8], b[9],
			b[10], b[11], b[12], b[13], b[14], b[15],
		]


static func get_current_time() -> String:
	# Get timestamp with sub-second precision.
	return get_time(Time.get_unix_time_from_system())

static func get_time(utc_timestamp: float) -> String:
	# If the time contains '.', split it and use part after '.' as subsecond, otherwise 0.
	var subsecond = "0" if str(utc_timestamp).find('.') < 0 else str(utc_timestamp).split('.')[1]
	return Time.get_datetime_string_from_unix_time(utc_timestamp, true) + '.' + subsecond + "+00:00"


static func parse_timestamptz(timestamp: String) -> float:
	# Parse unix time
	var unix := Time.get_unix_time_from_datetime_string(timestamp)
	# Expects PG format YYYY-MM-DD hh:mm:ss[.s+]+hh:ss
	# Parse subsecond and time zone
	var delta := 0
	var chr := timestamp.substr(timestamp.length() - 3, 1)
	if chr == ":":
		delta += timestamp.substr(-2).to_int()
		timestamp = timestamp.substr(0, timestamp.length() - 3)
		chr = timestamp.substr(timestamp.length() - 3, 1)
	if chr == "+" or chr == "-":
		delta += 60 * timestamp.substr(-2).to_int()
		if chr == "+":
			delta = -delta
	else:
		push_error("Invalid timestamptz")
		return 0.0
	timestamp = timestamp.substr(0, timestamp.length() - 3)
	var subsec := 0.0
	var idx := timestamp.find(".")
	if idx > 0:
		subsec = timestamp.substr(idx).to_float()
	return float(unix + (delta * 60)) + subsec
