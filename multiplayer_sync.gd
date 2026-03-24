extends Node

const REMOTE_SCENE := preload("res://remote_player.tscn")

var _peer: WebSocketPeer
var _my_id: int = -1
var _join_sent: bool = false
var _send_accum: float = 0.0
var _local_car: RigidBody3D
var _remote: Dictionary = {} # int -> Node3D
var _scene_root: Node3D
var _last_path: String = ""


func _ready() -> void:
	get_tree().scene_changed.connect(_on_scene_changed)
	call_deferred("_evaluate_scene")


func _on_scene_changed() -> void:
	call_deferred("_evaluate_scene")


func _evaluate_scene() -> void:
	var cur: Node = get_tree().current_scene
	var path := ""
	if cur:
		path = cur.scene_file_path
	if path == _last_path:
		return
	if _last_path.ends_with("city_map.tscn") and not path.ends_with("city_map.tscn"):
		_teardown()
	_last_path = path
	if not path.ends_with("city_map.tscn"):
		return
	if not GameSession.multiplayer_enabled:
		return
	_scene_root = cur as Node3D
	_local_car = _scene_root.find_child("car4", true, false) as RigidBody3D
	if not _local_car:
		push_warning("MultiplayerSync: no car4 RigidBody3D in scene")
		return
	_peer = WebSocketPeer.new()
	var err := _peer.connect_to_url(GameSession.get_ws_url())
	if err != OK:
		push_warning("MultiplayerSync: connect_to_url failed: %s" % err)
		_peer = null
		return
	_join_sent = false
	_my_id = -1


func _teardown() -> void:
	for id in _remote:
		var n: Node = _remote[id]
		if is_instance_valid(n):
			n.queue_free()
	_remote.clear()
	_my_id = -1
	_join_sent = false
	_send_accum = 0.0
	_local_car = null
	_scene_root = null
	if _peer:
		_peer.close()
		_peer = null


func _process(delta: float) -> void:
	if _peer == null:
		return
	if not is_instance_valid(_local_car) and _scene_root:
		_local_car = _scene_root.find_child("car4", true, false) as RigidBody3D
	_peer.poll()
	var st := _peer.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not _join_sent:
			var join: Dictionary = {"t": "join", "kind": "public"}
			if not GameSession.public_room:
				join = {"t": "join", "kind": "private", "n": GameSession.private_room_number}
			_send_json(join)
			_join_sent = true
		while _peer.get_available_packet_count() > 0:
			var pkt := _peer.get_packet()
			var text := pkt.get_string_from_utf8()
			_handle_message(text)
		_send_accum += delta
		if _send_accum >= 1.0 / 15.0 and is_instance_valid(_local_car) and _my_id >= 0:
			_send_accum = 0.0
			_send_state()
	elif st == WebSocketPeer.STATE_CLOSED:
		_teardown()


func _handle_message(text: String) -> void:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return
	var d: Dictionary = data
	match String(d.get("t", "")):
		"welcome":
			_my_id = int(d.get("id", -1))
		"peers":
			var ids = d.get("ids", [])
			if ids is Array:
				for x in ids:
					_ensure_remote(int(x))
		"player_joined":
			_ensure_remote(int(d.get("id", -1)))
		"player_left":
			var pid := int(d.get("id", -1))
			if _remote.has(pid):
				var n: Node = _remote[pid]
				if is_instance_valid(n):
					n.queue_free()
				_remote.erase(pid)
		"state":
			var pid := int(d.get("player", -1))
			if pid == _my_id or pid < 0:
				return
			var rp: Node3D = _ensure_remote(pid)
			if rp == null:
				return
			var pos_arr = d.get("pos")
			var rot_arr = d.get("rot")
			if typeof(pos_arr) != TYPE_ARRAY or typeof(rot_arr) != TYPE_ARRAY:
				return
			var pa: Array = pos_arr
			var ra: Array = rot_arr
			if pa.size() < 3 or ra.size() < 4:
				return
			var pos := Vector3(float(pa[0]), float(pa[1]), float(pa[2]))
			var quat := Quaternion(float(ra[0]), float(ra[1]), float(ra[2]), float(ra[3]))
			if rp.has_method("set_network_transform"):
				rp.call("set_network_transform", pos, quat)


func _ensure_remote(pid: int) -> Node3D:
	if pid < 0 or pid == _my_id:
		return null
	if _remote.has(pid):
		return _remote[pid]
	if _scene_root == null:
		return null
	var inst := REMOTE_SCENE.instantiate() as Node3D
	inst.set("player_id", pid)
	_scene_root.add_child(inst)
	inst.global_position = _local_car.global_position if _local_car else Vector3.ZERO
	_remote[pid] = inst
	return inst


func _send_state() -> void:
	if not is_instance_valid(_local_car):
		return
	var q := _local_car.global_transform.basis.get_rotation_quaternion()
	var payload := {
		"t": "state",
		"pos": [_local_car.global_position.x, _local_car.global_position.y, _local_car.global_position.z],
		"rot": [q.x, q.y, q.z, q.w],
		"vel": [_local_car.linear_velocity.x, _local_car.linear_velocity.y, _local_car.linear_velocity.z],
	}
	_send_json(payload)


func _send_json(obj: Dictionary) -> void:
	if _peer == null:
		return
	_peer.put_packet(JSON.stringify(obj).to_utf8_buffer())
