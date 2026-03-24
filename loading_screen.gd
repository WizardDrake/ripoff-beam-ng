extends Control

var _path: String = ""


func _ready() -> void:
	_path = GameSession.pending_scene_path
	GameSession.pending_scene_path = ""
	if _path.is_empty():
		push_warning("LoadingScreen: no pending_scene_path; returning to title.")
		get_tree().change_scene_to_file("res://title_screen.tscn")
		return
	var err := ResourceLoader.load_threaded_request(_path)
	if err != OK:
		push_error("LoadingScreen: load_threaded_request failed: %s" % err)
		get_tree().change_scene_to_file("res://title_screen.tscn")


func _process(_delta: float) -> void:
	if _path.is_empty():
		return
	var progress: Array = []
	var status := ResourceLoader.load_threaded_get_status(_path, progress)
	if progress.size() > 0:
		$VBoxContainer/ProgressBar.value = progress[0] * 100.0
	match status:
		ResourceLoader.THREAD_LOAD_LOADED:
			set_process(false)
			var packed := ResourceLoader.load_threaded_get(_path) as PackedScene
			_path = ""
			if packed == null:
				push_error("LoadingScreen: loaded resource was not a PackedScene")
				get_tree().change_scene_to_file("res://title_screen.tscn")
				return
			get_tree().change_scene_to_packed(packed)
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			set_process(false)
			_path = ""
			push_error("LoadingScreen: failed to load scene")
			get_tree().change_scene_to_file("res://title_screen.tscn")
