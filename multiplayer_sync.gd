extends Node

const REMOTE_SCENE := preload("res://remote_player.tscn")
const SupabaseClient := preload("res://addons/w4gd/supabase/client.gd")

var _peer: WebSocketPeer
var _my_id: int = -1
var _join_sent: bool = false
var _send_accum: float = 0.0
var _local_car: RigidBody3D
var _remote: Dictionary = {} # int -> Node3D
var _scene_root: Node3D
var _last_path: String = ""

# Supabase Realtime (when GameSession.uses_supabase_multiplayer())
var _sb_client: SupabaseClient
var _rt_sub: RefCounted
var _sb_subscribed: bool = false


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
	if GameSession.uses_supabase_multiplayer():
		_start_supabase_async.call_deferred()
	else:
		_start_custom_ws()


func _start_supabase_async() -> void:
	await _setup_supabase()


func _setup_supabase() -> void:
	_teardown_transport_only()
	_my_id = int(randi() % 1_000_000_000 + 1)
	var http_url := GameSession.get_supabase_url().trim_suffix("/")
	if not http_url.begins_with("http"):
		http_url = "https://" + http_url
	var key := GameSession.get_supabase_anon_key()
	_sb_client = SupabaseClient.new(self, http_url, key, TLSOptions.client())
	var rt = _sb_client.realtime
	var done := false
	var failed := false
	rt.connection_succeded.connect(func(): done = true, CONNECT_ONE_SHOT)
	rt.connection_error.connect(
		func():
			failed = true
			done = true,
		CONNECT_ONE_SHOT
	)
	var cerr := rt.connect_socket()
	if cerr != OK:
		push_warning("MultiplayerSync: Supabase connect_socket failed: %s" % cerr)
		_sb_client = null
		return
	var waited := 0.0
	while not done and waited < 15.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if failed or not done:
		push_warning("MultiplayerSync: Supabase Realtime did not connect (check URL, anon key, and Realtime settings).")
		if _sb_client:
			_sb_client.realtime.disconnect_socket(true)
			_sb_client = null
		return

	var ch_name := GameSession.supabase_room_channel()
	_rt_sub = rt.channel(
		ch_name,
		{"broadcast": {"self": true}, "presence": {"key": "p%d_%d" % [_my_id, randi()]}}
	)
	_rt_sub.received_broadcast.connect(_on_sb_broadcast)
	_rt_sub.received_presence.connect(_on_sb_presence)
	var sret: Variant = await _rt_sub.subscribe()
	if sret != OK:
		push_warning("MultiplayerSync: Supabase channel subscribe failed: %s" % sret)
		_teardown_transport_only()
		return
	_rt_sub.track({"player_id": _my_id})
	_sb_subscribed = true
	call_deferred("_rebuild_remotes_from_presence")


func _start_custom_ws() -> void:
	_peer = WebSocketPeer.new()
	var err := _peer.connect_to_url(GameSession.get_ws_url())
	if err != OK:
		push_warning("MultiplayerSync: connect_to_url failed: %s" % err)
		_peer = null
		return
	_join_sent = false
	_my_id = -1


func _teardown_transport_only() -> void:
	_sb_subscribed = false
	if _rt_sub:
		if _rt_sub.received_broadcast.is_connected(_on_sb_broadcast):
			_rt_sub.received_broadcast.disconnect(_on_sb_broadcast)
		if _rt_sub.received_presence.is_connected(_on_sb_presence):
			_rt_sub.received_presence.disconnect(_on_sb_presence)
		_rt_sub.unsubscribe()
		_rt_sub = null
	if _sb_client:
		_sb_client.realtime.disconnect_socket(true)
		_sb_client = null
	if _peer:
		_peer.close()
		_peer = null


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
	_teardown_transport_only()


func _process(delta: float) -> void:
	if not is_instance_valid(_local_car) and _scene_root:
		_local_car = _scene_root.find_child("car4", true, false) as RigidBody3D

	if GameSession.uses_supabase_multiplayer():
		if not _sb_subscribed or _rt_sub == null:
			return
		_send_accum += delta
		if _send_accum >= 1.0 / 15.0 and is_instance_valid(_local_car) and _my_id >= 0:
			_send_accum = 0.0
			_send_state_sb()
		return

	if _peer == null:
		return
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


func _on_sb_broadcast(data: Dictionary) -> void:
	if data.get("event") != "state":
		return
	var p: Variant = data.get("payload")
	if typeof(p) != TYPE_DICTIONARY:
		return
	_apply_state_dict(p as Dictionary)


func _on_sb_presence(event: String, _payload: Variant) -> void:
	if event in ["sync", "join", "leave"]:
		call_deferred("_rebuild_remotes_from_presence")


func _rebuild_remotes_from_presence() -> void:
	if _rt_sub == null:
		return
	var state: Dictionary = _rt_sub.get_presence_state()
	var alive: Dictionary = {}
	for k in state:
		var entries: Variant = state[k]
		if not entries is Array:
			continue
		for meta in entries:
			if not meta is Dictionary:
				continue
			var pid := int(meta.get("player_id", -1))
			if pid > 0:
				alive[pid] = true
				if pid != _my_id:
					_ensure_remote(pid)
	for pid in _remote.keys():
		if int(pid) != _my_id and not alive.has(pid):
			_remove_remote(int(pid))


func _remove_remote(pid: int) -> void:
	if not _remote.has(pid):
		return
	var n: Node = _remote[pid]
	if is_instance_valid(n):
		n.queue_free()
	_remote.erase(pid)


func _apply_state_dict(d: Dictionary) -> void:
	var pid := int(d.get("player", d.get("player_id", -1)))
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
			_remove_remote(pid)
		"state":
			_apply_state_dict(d)


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
		"player": _my_id,
		"pos": [_local_car.global_position.x, _local_car.global_position.y, _local_car.global_position.z],
		"rot": [q.x, q.y, q.z, q.w],
		"vel": [_local_car.linear_velocity.x, _local_car.linear_velocity.y, _local_car.linear_velocity.z],
	}
	_send_json(payload)


func _send_state_sb() -> void:
	if not is_instance_valid(_local_car) or _rt_sub == null:
		return
	var q := _local_car.global_transform.basis.get_rotation_quaternion()
	_rt_sub.broadcast(
		"state",
		{
			player = _my_id,
			pos = [_local_car.global_position.x, _local_car.global_position.y, _local_car.global_position.z],
			rot = [q.x, q.y, q.z, q.w],
			vel = [_local_car.linear_velocity.x, _local_car.linear_velocity.y, _local_car.linear_velocity.z],
		}
	)


func _send_json(obj: Dictionary) -> void:
	if _peer == null:
		return
	_peer.put_packet(JSON.stringify(obj).to_utf8_buffer())
