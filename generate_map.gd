extends SceneTree

func _init():
	print("Starting generation...")
	call_deferred("_start_generation")

func _start_generation():
	var root = Node3D.new()
	root.name = "CityMap"
	
	self.root.add_child(root)
	
	var env_node = WorldEnvironment.new()
	env_node.name = "WorldEnvironment"
	var sky = Sky.new()
	var mat = ProceduralSkyMaterial.new()
	sky.sky_material = mat
	var env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env_node.environment = env
	root.add_child(env_node)
	
	var light = DirectionalLight3D.new()
	light.name = "DirectionalLight"
	light.rotation_degrees = Vector3(-45, 45, 0)
	root.add_child(light)
	
	var crafter = load("res://addons/citycrafter/citycrafter.gd").new()
	crafter.name = "CityCrafter"
	root.add_child(crafter)
	
	self.edited_scene_root = root
	
	var config = load("res://addons/citycrafter/assets/example_city_resource.tres")
	crafter.city_configuration = config
	
	crafter.generation_complete.connect(_on_complete.bind(root))
	crafter.generate_city_async()

func _set_owner_recursive(node: Node, new_owner: Node):
	if node != new_owner:
		node.owner = new_owner
	for child in node.get_children():
		# DONT OVERRIDE internal instantiated child nodes, ONLY nodes we added!
		# Wait! Actually, setting owner on instantiated children breaks saving!
		# Godot PackedScene wants the root of an instance to be owned by main root,
		# and any dynamically added nodes to be owned by main root.
		# If a node has filename (it's the root of an instance), we set its owner.
		# If a node doesn't have filename, we only set its owner if it's not inside an instance...
		pass
		
	# Safe owner recursive:
	_safe_owner(node, new_owner)

func _safe_owner(node: Node, main_owner: Node):
	if node != main_owner:
		node.owner = main_owner
	for child in node.get_children():
		# If child was part of an instance, its owner was the instance root.
		# We should ONLY change its owner to main_owner if we dynamically generated it.
		# Since we generated the StaticBody3D dynamically, it has no owner.
		if child.owner == null or child.owner == main_owner:
			_safe_owner(child, main_owner)
		elif child.name == "SolidPhysics" or child is CollisionShape3D:
			_safe_owner(child, main_owner)

func _on_complete(root):
	print("Generation complete, adding car...")
	var car_scene = load("res://scenes/fincar4.tscn")
	if not car_scene:
		car_scene = load("res://scenes/car4.tscn")
	if car_scene:
		var car = car_scene.instantiate()
		car.position = Vector3(50, 2, 50)
		root.add_child(car)
		
	_set_owner_recursive(root, root)
	
	print("Packing scene...")
	var packed = PackedScene.new()
	var result = packed.pack(root)
	if result == OK:
		var err = ResourceSaver.save(packed, "res://city_map.tscn")
		if err == OK:
			print("SUCCESS: Saved city_map.tscn")
		else:
			print("ERROR: Failed to save res://city_map.tscn, error code: ", err)
	else:
		print("ERROR: Failed to pack scene, error code: ", result)
	
	quit()
