extends Control


func _ready() -> void:
	$VBoxContainer/SingleplayerButton.grab_focus()


func _go_to_city_map() -> void:
	GameSession.pending_scene_path = "res://city_map.tscn"
	get_tree().change_scene_to_file(GameSession.LOADING_SCREEN_PATH)


func _on_singleplayer_pressed() -> void:
	GameSession.multiplayer_enabled = false
	_go_to_city_map()


func _on_public_pressed() -> void:
	GameSession.multiplayer_enabled = true
	GameSession.public_room = true
	_go_to_city_map()


func _on_private_pressed() -> void:
	var n := int($VBoxContainer/PrivateRow/RoomSpin.value)
	n = clampi(n, 1, 100)
	$VBoxContainer/PrivateRow/RoomSpin.value = n
	GameSession.multiplayer_enabled = true
	GameSession.public_room = false
	GameSession.private_room_number = n
	_go_to_city_map()
