extends SceneTree

func _init():
	print("Testing live collision...")
	var scene = load("res://city_map.tscn")
	var root = scene.instantiate()
	root.name = "root"
	self.root.add_child(root)
	
	# Give physics 1 frame to initialize
	call_deferred("test_ray")

func test_ray():
	var space = root.get_child(0).get_world_3d().direct_space_state
	for b in root.get_child(0).find_children("building*"):
		if b is Node3D:
			var pos = b.global_position + Vector3(0, 50, 0)
			var query = PhysicsRayQueryParameters3D.create(pos, pos + Vector3(0, -100, 0))
			var result = space.intersect_ray(query)
			if result:
				print("Hit building physics! collider: ", result.collider)
			else:
				print("Missed building!")
			break
	quit()
