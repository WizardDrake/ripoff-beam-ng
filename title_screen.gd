extends Control

func _ready() -> void:
	# Ensure the button is focused for controller/keyboard support
	$VBoxContainer/PlayButton.grab_focus()

func _on_play_button_pressed() -> void:
	get_tree().change_scene_to_file("res://city_map.tscn")
