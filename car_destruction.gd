extends Node3D
class_name CarDestruction

## Pre-loaded physics-based progressive car destruction.
##
## At startup, every mesh part of the car body is converted into its own
## RigidBody3D frozen in place at its correct position. The frozen bodies
## move with the car perfectly. On collision, nearby parts unfreeze and
## fly off realistically with their original materials/textures.
##
## Location is determined by each mesh's AABB center, not the node origin,
## so parts nearest the actual impact point are detached first.

@export var car_node_path: NodePath = "car4"
## Minimum speed-loss (deceleration) to trigger part detachment.
@export var impact_speed_threshold: float = 3.0
## Max parts to detach per collision.
@export var max_parts_per_impact: int = 15
## Search radius from impact point (scaled by speed).
@export var base_detach_radius: float = 2.5
## Force multiplier on detached parts.
@export var detach_force: float = 5.0
## Collision cooldown in seconds.
@export var cooldown: float = 0.3

@export_group("Engine Explosion")
## Local position of the engine (front of car is -Z). If a part here breaks, car explodes.
@export var engine_location: Vector3 = Vector3(0, 0.5, -1.2)
## Radius around the engine location that counts as critical.
@export var engine_radius: float = 0.6
## Force multiplier when the engine explodes.
@export var engine_explosion_force: float = 2.0

var _car: RigidBody3D
var _previous_velocity: Vector3 = Vector3.ZERO
var _cooldown_timer: float = 0.0
var _engine_exploded := false

## Each entry: { body, local_xform, local_center, attached }
## local_center is the mesh AABB center in car-local space (for sorting by proximity)
var _parts: Array[Dictionary] = []


func _ready() -> void:
	_car = get_node(car_node_path) as RigidBody3D
	if not _car:
		push_warning("CarDestruction: car not found at %s" % car_node_path)
		return

	_car.contact_monitor = true
	_car.max_contacts_reported = 4
	_car.continuous_cd = true
	_car.body_entered.connect(_on_car_body_entered)

	# Defer the heavy setup so the scene finishes loading first
	call_deferred("_build_parts")


func _build_parts() -> void:
	if not _car or not is_instance_valid(_car):
		return

	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(_car, meshes)

	for mesh_node in meshes:
		_create_part(mesh_node)


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	for child in node.get_children():
		if child is RayCast3D:
			continue
		if child.name == "Destruction" or child.name == "CollisionShape3D":
			continue
		if child is MeshInstance3D and child.mesh:
			out.append(child)
		_collect_meshes(child, out)


func _create_part(mesh_node: MeshInstance3D) -> void:
	var world_xform := mesh_node.global_transform
	var mesh := mesh_node.mesh
	var mat_override := mesh_node.material_override
	var surface_mats := {}
	for i in mesh.get_surface_count():
		var m = mesh_node.get_surface_override_material(i)
		if m:
			surface_mats[i] = m

	var aabb := mesh.get_aabb()
	var mesh_center_local := aabb.get_center()
	var mesh_center_world: Vector3 = world_xform * mesh_center_local
	var local_center: Vector3 = _car.global_transform.affine_inverse() * mesh_center_world
	var local_xform: Transform3D = _car.global_transform.affine_inverse() * world_xform

	mesh_node.get_parent().remove_child(mesh_node)
	mesh_node.queue_free()

	var body := RigidBody3D.new()
	body.mass = 1.0
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	body.continuous_cd = true
	body.collision_layer = 0
	body.collision_mask = 0

	var new_mesh := MeshInstance3D.new()
	new_mesh.mesh = mesh
	if mat_override:
		new_mesh.material_override = mat_override
	for idx in surface_mats:
		new_mesh.set_surface_override_material(idx, surface_mats[idx])

	var col := CollisionShape3D.new()
	col.shape = mesh.create_convex_shape(true, true)
	body.add_child(new_mesh)
	body.add_child(col)

	_car.get_parent().add_child(body)
	body.global_transform = world_xform

	_parts.append({
		"body": body,
		"local_xform": local_xform,
		"local_center": local_center,
		"attached": true,
		"health": 100.0
	})


func _physics_process(delta: float) -> void:
	if not _car or not is_instance_valid(_car):
		return

	var current_vel := _car.linear_velocity
	var speed_loss := _previous_velocity.length() - current_vel.length()
	if speed_loss > impact_speed_threshold and _cooldown_timer <= 0.0:
		var impact_dir := _previous_velocity.normalized()
		var impact_point := _car.global_position + impact_dir * 0.6
		var count := clampi(int(speed_loss / impact_speed_threshold), 1, max_parts_per_impact)
		_handle_impact(impact_point, speed_loss, count)

	_previous_velocity = current_vel

	if _cooldown_timer > 0.0:
		_cooldown_timer -= delta

	var car_xform := _car.global_transform
	for part in _parts:
		if not part.attached:
			continue
		var body: RigidBody3D = part.body
		if not is_instance_valid(body):
			continue
		body.global_transform = car_xform * part.local_xform


func is_engine_exploded() -> bool:
	return _engine_exploded


func _unhandled_input(event: InputEvent) -> void:
	if not _car or not is_instance_valid(_car):
		return
	if event.is_action_pressed("destroy_car") and not _engine_exploded:
		_explode_entire_car()


func _on_car_body_entered(_body: Node) -> void:
	# We no longer trigger damage simply from touching objects, because
	# scraping a wall at 50mph would instantly deal 50mph worth of damage.
	# Destruction is now purely handled in _physics_process by measuring
	# sudden deceleration (G-forces/impact intensity).
	pass


func _get_part_world_center(part: Dictionary) -> Vector3:
	return _car.global_transform * (part.local_center as Vector3)


func _handle_impact(impact_point: Vector3, speed: float, max_detach: int) -> void:
	_cooldown_timer = cooldown

	var attached: Array[Dictionary] = []
	for part in _parts:
		if part.attached and is_instance_valid(part.body):
			attached.append(part)

	if attached.is_empty():
		return

	# Convert impact point to car-local space for crushing calculations
	var local_impact := _car.global_transform.affine_inverse() * impact_point

	attached.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var da: float = (a.local_center as Vector3).distance_to(local_impact)
		var db: float = (b.local_center as Vector3).distance_to(local_impact)
		return da < db
	)

	# Cap the radius to a maximum of 2.0 meters so high speeds don't crumple the entire car
	var effective_radius := minf(base_detach_radius * (speed / impact_speed_threshold), 2.0)
	var detached := 0

	for part in attached:
		var dist := (part.local_center as Vector3).distance_to(local_impact)
		if dist > effective_radius:
			continue

		# Intensity of damage is higher closer to impact center
		var damage_ratio := clampf(1.0 - (dist / effective_radius), 0.0, 1.0)
		var damage_amount := damage_ratio * speed
		
		# Engine parts are much more durable
		var is_engine := (part.local_center as Vector3).distance_to(engine_location) < engine_radius
		var damage_mult := 1.0 if is_engine else 60.0
		
		# Take damage
		part.health -= damage_amount * damage_mult

		if part.health <= 0.0 and detached < max_detach:
			_release_part(part, impact_point, speed)
			detached += 1
		else:
			# CRUMPLE the part: move it inward toward the crash, rotate weirdly, scale down
			var local_center := part.local_center as Vector3
			var crush_dir: Vector3 = (local_impact - local_center).normalized()
			if crush_dir.length_squared() < 0.01:
				crush_dir = Vector3.DOWN
				
			# Clamp maximum deformation per hit so it doesn't warp insanely
			var deform_severity := clampf(damage_amount, 0.0, 5.0)
				
			var inward_push: Vector3 = crush_dir * (deform_severity * 0.005)
			part.local_xform.origin += inward_push
			part.local_center = local_center + inward_push
			
			part.local_xform = part.local_xform.rotated_local(Vector3.RIGHT, randf_range(-0.005, 0.005) * deform_severity)
			part.local_xform = part.local_xform.rotated_local(Vector3.UP, randf_range(-0.005, 0.005) * deform_severity)
			part.local_xform = part.local_xform.rotated_local(Vector3.FORWARD, randf_range(-0.005, 0.005) * deform_severity)
			
			# Uniform crush scaling to simulate denting
			var crush_scale := 1.0 - (deform_severity * 0.002)
			part.local_xform = part.local_xform.scaled_local(Vector3(crush_scale, crush_scale, crush_scale))


func _release_part(part: Dictionary, impact_point: Vector3, speed: float) -> void:
	part.attached = false
	var body: RigidBody3D = part.body
	var center := _get_part_world_center(part)

	# Unfreeze — enable full physics
	body.freeze = false
	body.gravity_scale = 1.0
	
	# Layer 0: other parts won't hit it. Mask 1: it will hit the ground.
	body.collision_layer = 0
	body.collision_mask = 1
	
	# Prevent it from ever colliding with the main car chassis so it passes right through
	_car.add_collision_exception_with(body)

	# Give it the car's current velocity so it doesn't just drop, but 
	# significantly dampen it so it doesn't tunnel through walls if it's already clipping!
	body.linear_velocity = _previous_velocity * 0.15

	# Impulse away from impact — use the mesh center, not node origin
	var away := (center - impact_point).normalized()
	if away.length_squared() < 0.01:
		away = Vector3.UP + Vector3(randf() - 0.5, 0.0, randf() - 0.5)
	
	# Push slightly backwards towards the car's center to get it out of the wall!
	var back_to_car := (_car.global_position - center).normalized()
	body.global_position += back_to_car * 0.25
	
	body.apply_impulse(away * detach_force * (speed / 10.0))
	body.apply_torque_impulse(Vector3(
		randf() - 0.5, randf() - 0.5, randf() - 0.5
	) * detach_force * 0.5)

	# Check if this part was part of the engine zone
	if not _engine_exploded:
		var local_center := part.local_center as Vector3
		if local_center.distance_to(engine_location) < engine_radius:
			_explode_entire_car()


func _explode_entire_car() -> void:
	if _engine_exploded or not is_instance_valid(_car):
		return
	_engine_exploded = true
	
	# The explosion originates from the engine
	var center_of_explosion := _car.global_transform * engine_location
	
	# Instantly detach all remaining parts with very low force so they just fall into a pile
	for p in _parts:
		if p.attached:
			_release_part(p, center_of_explosion, engine_explosion_force)
			
	# Give the main car chassis a tiny bump so the wheel chassis collapses nicely
	_car.apply_impulse(Vector3.UP * engine_explosion_force * 2.0, engine_location)
	_car.apply_torque_impulse(Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * engine_explosion_force)
