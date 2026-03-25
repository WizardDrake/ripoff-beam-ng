extends Node

## Set before opening [member loading_screen_path]; cleared when loading starts.
var pending_scene_path: String = ""

## Scene used to show progress while [member pending_scene_path] loads in the background.
const LOADING_SCREEN_PATH := "res://loading_screen.tscn"

## Session flags set from the title screen before changing to the city map.
var multiplayer_enabled: bool = false
## If [code]true[/code], join the shared public room; otherwise use [member private_room_number].
var public_room: bool = true
## Private room index in the range 1–100 (only used when [member public_room] is [code]false[/code]).
var private_room_number: int = 1


func get_ws_url() -> String:
	if ProjectSettings.has_setting("multiplayer/ws_url"):
		return ProjectSettings.get_setting("multiplayer/ws_url")
	return "ws://127.0.0.1:8787"


func get_supabase_url() -> String:
	if ProjectSettings.has_setting("multiplayer/supabase_url"):
		return String(ProjectSettings.get_setting("multiplayer/supabase_url")).strip_edges()
	return ""


func get_supabase_anon_key() -> String:
	if ProjectSettings.has_setting("multiplayer/supabase_anon_key"):
		return String(ProjectSettings.get_setting("multiplayer/supabase_anon_key")).strip_edges()
	return ""


func uses_supabase_multiplayer() -> bool:
	return not get_supabase_url().is_empty() and not get_supabase_anon_key().is_empty()


func supabase_room_channel() -> String:
	if public_room:
		return "mp_public"
	return "mp_pr_%d" % clampi(private_room_number, 1, 100)
