extends Node3D

@export var player_id: int = 0

var _target_pos: Vector3 = Vector3.ZERO
var _target_quat: Quaternion = Quaternion.IDENTITY


func _ready() -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(2.2, 1.4, 4.5)
	mesh.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color_for_id(player_id)
	mesh.material_override = mat
	add_child(mesh)


func set_network_transform(pos: Vector3, quat: Quaternion) -> void:
	_target_pos = pos
	_target_quat = quat


func _physics_process(delta: float) -> void:
	global_position = global_position.lerp(_target_pos, minf(1.0, delta * 14.0))
	var q := global_transform.basis.get_rotation_quaternion().slerp(_target_quat, minf(1.0, delta * 14.0))
	global_transform.basis = Basis(q)


func _color_for_id(pid: int) -> Color:
	return Color.from_hsv(float(posmod(pid * 47, 360)) / 360.0, 0.65, 0.9)
