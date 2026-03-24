extends SceneTree

func _init():
	print("Testing building AABB...")
	var scene = load("res://addons/citycrafter/assets/example_assets/kenney_city-kit-suburban_20/Models/GLB format/building-type-c.glb")
	if not scene:
		print("Failed")
		quit()
		return
	var building = scene.instantiate()
	_add_collision_to_building(building)
	quit()

func _add_collision_to_building(node: Node):
	if node is MeshInstance3D and node.mesh:
		var aabb = node.mesh.get_aabb()
		print("Mesh: ", node.name, " AABB Size: ", aabb.size, " Center: ", aabb.get_center())
	for child in node.get_children():
		_add_collision_to_building(child)
