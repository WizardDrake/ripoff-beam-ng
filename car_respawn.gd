extends Node

const VEHICLE_SCENE := preload("res://scenes/fincar4.tscn")

var _spawn_transform: Transform3D


func _ready() -> void:
	var root := get_parent() as Node3D
	if root:
		_spawn_transform = root.global_transform


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("respawn"):
		return
	var car_root := get_parent() as Node3D
	if car_root == null:
		return
	var destruction := car_root.get_node_or_null("CarDestruction") as CarDestruction
	if destruction == null or not destruction.is_engine_exploded():
		return
	var parent := car_root.get_parent()
	if parent == null:
		return
	var fresh := VEHICLE_SCENE.instantiate() as Node3D
	parent.add_child(fresh)
	fresh.global_transform = _spawn_transform
	car_root.queue_free()
	get_viewport().set_input_as_handled()
