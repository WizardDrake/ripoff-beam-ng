## Interacts with the W4 Cloud matchmaker component.
extends Node

const SupabaseClient = preload("../supabase/client.gd")
const TableSynchronizer = preload("../supabase/table_synchronizer.gd")
const Parser = preload("../supabase/poly_result.gd")
const Realtime = preload("../supabase/realtime.gd")
const PolyResult = Parser.PolyResult
const Promise = preload("../rest/client_promise.gd")
const Request = preload("../rest/client_request.gd")
const WebRTCManager = preload("webrtc_manager.gd")

## The lobby type.
enum LobbyType {
	## A lobby that doesn't use W4 Cloud's dedicated server or WebRTC systems.
	LOBBY_ONLY = 0,
	## A lobby that needs a dedicated server allocated.
	DEDICATED_SERVER = 1,
	## A lobby that will use the WebRTC signalling server to create a full peer-to-peer mesh with all players.
	WEBRTC_PLAYER_MESH = 2,
	# Deprecated. Use [code]WEBRTC_PLAYER_MESH[/code].
	WEBRTC = 2,
	## A lobby that will use the WebRTC signalling server. All players (but the lobby creator) will connect to the lobby creator's client, who hosts the game.
	WEBRTC_PLAYER_HOST = 3,
	## A lobby that will use the WebRTC signalling server and needs a dedicated server. All players connect to the dedicated gameserver.
	WEBRTC_DEDICATED_SERVER = 4,
}

## The lobby state.
enum LobbyState {
	## A newly created lobby.
	NEW = 1,
	## The match is now in progress (players can still join and leave).
	IN_PROGRESS = 2,
	## The match is in progress, but sealed, meaning players can no longer join or leave.
	SEALED = 3,
	## The match is done and this lobby can be cleaned up.
	DONE = 4,
}

## DEPRECATED: Represents access granted to a dedicated server.
class ServerTicket extends RefCounted:
	## The IP of the server to connect to.
	var ip: String
	## The port of the server to connect to.
	var port: int
	## A secret used to verify that this player has permission to connect to this server.
	var secret: String

	## Creates a new server ticket.
	func _init(p_server_uri: String, p_secret: String):
		var server_parts = p_server_uri.split(':')
		ip = server_parts[0]
		port = server_parts[1].to_int()
		secret = p_secret

## Represents the players place in the matchmaking queue.
class MatchmakerTicket extends RefCounted:
	## The ticket ID.
	var id: String
	## The ID of the lobby (if any) that was created by the matchmaker for this ticket.
	var lobby_id: String

	## Emitted when a lobby is created for this ticket.
	signal matched (lobby_id)

	## Creates a matchmaker ticket.
	func _init(p_id: String):
		id = p_id

	func _match(p_lobby: String) -> void:
		lobby_id = p_lobby
		matched.emit(lobby_id)

## A collection of players who are in (about to be in) a match together.
class Lobby extends RefCounted:

	## Properties or settings for this lobby.
	var props: Dictionary

	## The current lobby state.
	var state: LobbyState = LobbyState.NEW

	## Emitted when the lobby is updated.
	signal updated ()
	## Deprecated: Called when the player leaves the lobby, replaced by the `left` signal.
	signal deleted ()
	## Emitted when current user has been added to the lobby.
	signal joined ()
	## Emitted when current user has been removed from the lobby (or if the lobby is deleted).
	signal left ()
	## Emitted when a player joins the lobby.
	signal player_joined (player_id)
	## Emitted when a player leaves the lobby.
	signal player_left (player_id)
	## Deprecated: Replaced by `gameserver_ready`.
	signal received_server_ticket (ticket)
	## Emitted when the gameserver is ready and the game can be joined.
	signal gameserver_ready (ip, port, secret)
	## Deprecated: Same as `webrtc_multiplayer_peer_created`.
	signal webrtc_mesh_created (multiplayer_peer)
	## Emitted when a WebRTC mesh is created.
	signal webrtc_multiplayer_peer_created (multiplayer_peer)
	## Emitted when connections to all WebRTC peers have been established.
	signal webrtc_peers_ready ()
	## Emitted when one or more of the WebRTC peers is no longer connected, or a new peer has joined that we haven't connected to yet.
	signal webrtc_peers_not_ready ()

	var _id: String
	## The lobby ID.
	var id: String:
		get:
			return _id
		set(v):
			push_error("Lobby.id is a read-only property")

	var _type: LobbyType
	## The lobby type.
	var type: LobbyType:
		get:
			return _type
		set(v):
			push_error("Lobby.type is a read-only property")

	var _creator_id: String
	## The ID of the player who created the lobby (if any).
	var creator_id: String:
		get:
			return _creator_id
		set(v):
			push_error("Lobby.creator_id is a read-only property")

	var _max_players: int
	## The maximum number of players allowed in this lobby.
	var max_players: int:
		get:
			return _max_players
		set(v):
			push_error("Lobby.max_players is a read-only property")

	var _created_at: float
	## When the lobby was created (in UNIX time).
	var created_at: float:
		get:
			return _created_at
		set(v):
			push_error("Lobby.created_at is a read-only property")

	var _updated_at: float
	## When the lobby was last updated (in UNIX time).
	var updated_at: float:
		get:
			return _updated_at
		set(v):
			push_error("Lobby.updated_at is a read-only property")

	var _hidden: bool
	## Whether or not this lobby is hidden.
	var hidden: bool:
		get:
			return _hidden
		set(v):
			push_error("Lobby.hidden is a read-only property")

	var _cluster: String
	## The name of the cluster when using a dedicated server lobby.
	var cluster: String:
		get:
			return _cluster
		set(v):
			push_error("Lobby.cluster is a read-only property")

	var _gameserver_uri: String
	## The name of the cluster when using a dedicated server lobby.
	var gameserver_uri: String:
		get:
			return _gameserver_uri
		set(v):
			push_error("Lobby.gameserver_uri is a read-only property")

	var _players: Array[String]
	var _secret: String
	var _webrtc_manager: WebRTCManager

	var _client: SupabaseClient
	var _realtime_user_channel : Realtime.Subscription
	var _is_subscribed: bool = false

	## Creates a new lobby.
	func _init(p_client: SupabaseClient, p_data: Dictionary, p_webrtc_ice_servers: Array, p_poll_signal: Signal, p_subscribe: bool):
		_id = p_data['id']
		_update_data(p_data)

		_client = p_client

		if _type == LobbyType.WEBRTC_PLAYER_MESH or _type == LobbyType.WEBRTC_PLAYER_HOST or _type == LobbyType.WEBRTC_DEDICATED_SERVER:
			var mode = WebRTCManager.MultiplayerPeerMode.MESH if _type == LobbyType.WEBRTC_PLAYER_MESH else WebRTCManager.MultiplayerPeerMode.CLIENT_SERVER
			_webrtc_manager = WebRTCManager.new(_client, _id, mode, p_webrtc_ice_servers, p_subscribe)
			_webrtc_manager.multiplayer_peer_created.connect(_on_webrtc_manager_multiplayer_peer_created)
			_webrtc_manager.peers_ready.connect(_on_webrtc_manager_peers_ready)
			_webrtc_manager.peers_not_ready.connect(_on_webrtc_manager_peers_not_ready)
			p_poll_signal.connect(_webrtc_manager.poll)

		if p_subscribe:
			subscribe()

	func subscribe() -> void:
		if _is_subscribed:
			return
		_is_subscribed = true

		var uid = _client.get_identity().get_uid()
		_realtime_user_channel = _client.realtime.channel("user#"+uid, { "private": true } )
		_realtime_user_channel.received_broadcast.connect(self._on_message_received)
		_realtime_user_channel.subscribe()

		if _type == LobbyType.WEBRTC_PLAYER_MESH or _type == LobbyType.WEBRTC_PLAYER_HOST or _type == LobbyType.WEBRTC_DEDICATED_SERVER:
			_webrtc_manager.subscribe()

	func unsubscribe() -> void:
		if _realtime_user_channel:
			_realtime_user_channel.unsubscribe()
			_realtime_user_channel = null

		if _webrtc_manager:
			_webrtc_manager.unsubscribe()

		_is_subscribed = false

	func is_subscribed() -> bool:
		return _is_subscribed

	func _update_data(p_data: Dictionary) -> void:
		var at := W4Utils.parse_timestamptz(p_data['updated_at'])
		if at < _updated_at:
			return

		_updated_at = at
		_type = p_data['type']
		_creator_id = p_data['creator_id'] if p_data['creator_id'] != null else ''
		_max_players = p_data['max_players']
		_created_at = W4Utils.parse_timestamptz(p_data['created_at'])
		_hidden = p_data['hidden']
		_cluster = p_data['cluster'] if p_data['cluster'] != null else ''

		props = p_data['props']
		state = p_data['state']

	func _on_webrtc_manager_multiplayer_peer_created(multiplayer_peer: WebRTCMultiplayerPeer) -> void:
		webrtc_multiplayer_peer_created.emit(multiplayer_peer)
		webrtc_mesh_created.emit(multiplayer_peer)

	func _on_webrtc_manager_peers_ready() -> void:
		webrtc_peers_ready.emit()

	func _on_webrtc_manager_peers_not_ready() -> void:
		webrtc_peers_not_ready.emit()

	## Returns true if the currently logged in user is the creator of this lobby.
	func is_creator() -> bool:
		var identity = _client.get_identity()
		if not identity.is_authenticated():
			return false
		return identity.get_uid() == _creator_id

	## Gets the current player list.
	func get_players() -> Array[String]:
		return _players

	## Creates a request to refresh the player list.
	func refresh_player_list() -> Request:
		var request = _client.rest.rpc('w4public.lobby_get_presence', {
			lobby_id = _id,
		})

		var handle_result = func(result):
			if result.is_error():
				return result

			var new_players : Array = result.users.as_array()

			for player_id in new_players:
				if not player_id in new_players:
					player_joined.emit(player_id)
			for player_id in _players:
				if not player_id in new_players:
					player_left.emit(player_id)

			_players.assign(new_players)

			return PolyResult.new(_players)

		return request.then(handle_result)

	## Gets the server ticket for this lobby (if any).
	## DEPRECATED
	func get_server_ticket() -> ServerTicket:
		if !_gameserver_uri or !_secret:
			return null
		return ServerTicket.new(_gameserver_uri, _secret)

	## Creates a request to refresh the server ticket for this lobby.
	func refresh_server_ticket() -> Request:
		var request = _client.rest.rpc('w4public.lobby_get_ticket', {
			lobby_id = _id,
		})

		var handle_result = func(result):
			if result.is_error():
				return result

			if result.secret.is_null():
				return PolyResult.new()

			_secret = result.secret.as_string()
			_gameserver_uri = result.uri.as_string()
			_emit_ticket_updated.call_deferred()
			return PolyResult.new(_secret)

		return request.then(handle_result)

	func _emit_ticket_updated():
		received_server_ticket.emit(ServerTicket.new(_gameserver_uri, _secret))
		## DEPRECATED
		if not gameserver_uri.is_empty():
			gameserver_ready.emit()

	## Creates a request to refresh the WebRTC sessions for this lobby.
	func refresh_webrtc_sessions() -> Request:
		if not _webrtc_manager:
			push_error("Not a WebRTC lobby")
			return null
		return _webrtc_manager.refresh_sessions()

	## Gets the WebRTC multiplayer peer for this lobby (if any).
	func get_webrtc_multiplayer_peer() -> WebRTCMultiplayerPeer:
		if not _webrtc_manager:
			push_error("Not a WebRTC lobby")
			return null
		return _webrtc_manager.webrtc_multiplayer_peer

	## Gets the WebRTC manager.
	func get_webrtc_manager() -> WebRTCManager:
		if not _webrtc_manager:
			push_error("Not a WebRTC lobby")
			return null
		return _webrtc_manager

	## Creates a request to save any changed properties on the lobby.
	func save() -> Request:
		var request = _client.rest.rpc('w4public.lobby_update', {
			lobby_id = _id,
			props = props,
			state = state,
		})

		var handle_result = func(result):
			if result.is_error():
				return result
			return PolyResult.new()

		return request.then(handle_result)

	## Creates a request to leave the lobby.
	func leave() -> Request:
		var request = _client.rest.rpc('w4public.lobby_leave', {
			lobby_id = _id,
		})

		var handle_result = func(result):
			if result.is_error():
				return result
			return PolyResult.new()

		return request.then(handle_result)

	## Creates a request to delete the lobby.
	func delete() -> Request:
		var request = _client.rest.rpc('w4public.lobby_delete', {
			lobby_id = _id,
		})

		var handle_result = func(result):
			if result.is_error():
				return result
			return PolyResult.new()

		return request.then(handle_result)

	func _on_lobby_updated(p_lobby) -> void:
		_update_data(p_lobby)
		updated.emit()

	func _on_message_received(p_data: Dictionary) -> void:
		if not p_data.has("event"):
			push_error("Realtime message received without an \"event\" field")
			return
		if not p_data.has("payload"):
			push_error("Realtime message received without a \"payload\" field")
			return
		var event := p_data["event"] as String
		if not event.begins_with("lobby_"):
			return

		var payload = p_data["payload"]

		var lobby_id := (payload["lobby"] as Dictionary).get("id", "") as String
		if lobby_id.is_empty():
			push_error("Invalid or missing lobby id")
			return
		if lobby_id != _id:
			return

		if event == "lobby_updated":
			_on_lobby_updated(p_data["payload"]["lobby"])
		elif event == "lobby_joined":
			joined.emit()
		elif event == "lobby_left":
			left.emit()
			deleted.emit() # Deprecated
		elif event == "lobby_player_joined":
			var player := payload.get("player", "") as String
			if player.is_empty():
				push_error("Invalid or missing \"player\" field")
				return
			if player in _players:
				return
			_players.append(player)
			player_joined.emit(player)
		elif event == "lobby_player_left":
			var player := payload.get("player", "") as String
			if player.is_empty():
				push_error("Invalid or missing \"player\" field")
				return
			if player not in _players:
				return
			_players.erase(player)
			player_left.emit(player)
		elif event == "lobby_ticket_changed":
			var ticket := payload.get("lobby_ticket", {}) as Dictionary
			if ticket.is_empty():
				push_error("Invalid or missing \"lobby_ticket\" field")
				return
			# Udpate the secret
			_secret = ticket.get("secret", "")
			var uri = ticket.get("uri")
			if typeof(uri) == TYPE_STRING:
				_gameserver_uri = ticket.get("uri")
			if _webrtc_manager != null:
				_webrtc_manager.set_lobby_secret(_secret)

			# Trigger a signal when the gameserver is ready to join.
			if _type == LobbyType.DEDICATED_SERVER and state in [LobbyState.IN_PROGRESS, LobbyState.SEALED]:
				_emit_ticket_updated()
		else:
			push_error("Realtime message received with unknown event type: " + p_data["event"])
			return

## The default WebRTC ICE servers, if none are provided.
const DEFAULT_WEBRTC_ICE_SERVERS := [
	{
		"urls": [
			"stun:stun.l.google.com:19302",
			"stun:stun1.l.google.com:19302",
			"stun:stun2.l.google.com:19302",
			"stun:stun3.l.google.com:19302",
			"stun:stun4.l.google.com:19302",
		],
	},
]

var _client: SupabaseClient
var _webrtc_ice_servers: Array = DEFAULT_WEBRTC_ICE_SERVERS
var _matchmaker_tickets := {}
var _matchmaker_channel

signal _poll ()

func _init(p_client: SupabaseClient):
	_client = p_client
	_client.get_identity().identity_changed.connect(self._subscribe_to_matchmaker_channel)
	_subscribe_to_matchmaker_channel()

func _process(_delta) -> void:
	_poll.emit()

## Sets the list of WebRTC ICE servers.
func set_webrtc_ice_servers(p_ice_servers: Array) -> void:
	_webrtc_ice_servers = p_ice_servers

## Gets a list of valid dedicated server cluster names.
func get_cluster_list() -> Request:
	return _client.rest.rpc_const('w4public.cluster_get_all')

## Creates a request to create a new lobby. A ["addons/w4gd/matchmaker/matchmaker.gd".Lobby] will be returned as the data.
##
## [param p_opts] can contain the following keys:
## - [code]props[/code]: A [Dictionary] of lobby properties to be used as needed by your game.
## - [code]max_players[/code]: The maximum number of players allowed in the lobby (the default is [code]2[/code]).
## - [code]initial_players[/code]: An [Array] of player UUIDs to add to automatically join to the lobby.
## - [code]cluster[/code]: The name of the cluster to allocate the dedicated server when using a dedicated server lobby.
## - [code]hidden[/code]: If [code]true[/code], the lobby will not be publicly listable.
func create_lobby(p_type: LobbyType = LobbyType.LOBBY_ONLY, p_opts := {}, p_subscribe: bool = true) -> Request:
	var props = p_opts.get('props', {})
	var max_players = p_opts.get('max_players', 2)
	var prealloc_players = p_opts.get('initial_players', [])
	var cluster = p_opts.get('cluster', null) if p_type == LobbyType.DEDICATED_SERVER else null
	var hidden = p_opts.get('hidden', false)

	if p_type == LobbyType.WEBRTC_DEDICATED_SERVER:
		push_error("'Lobbype.WEBRTC_DEDICATED_SERVER' is not supported in this version of the SDK")
		assert(false)
		return null

	if p_opts.has('fleet_labels') and p_opts['fleet_labels'] is Dictionary:
		props['gameServerSelectors'] = [{
			matchLabels = p_opts['fleet_labels']
		}]

	var request = _client.rest.rpc('w4public.lobby_create', {
		type = p_type,
		props = props,
		max_players = max_players,
		prealloc_players = prealloc_players,
		cluster = cluster,
		hidden = hidden,
	})

	var handle_result = func(result):
		if result.is_error():
			return result

		var lobby = Lobby.new(_client, result.lobby.as_dict(), _webrtc_ice_servers, _poll, p_subscribe)

		var players : Array[String] = []
		for ticket in result.tickets.as_array():
			if ticket['player_id'] != null:
				players.append(ticket['player_id'])
		lobby._players = players

		return PolyResult.new(lobby)

	return request.then(handle_result)

## Creates a request to join a lobby. A ["addons/w4gd/matchmaker/matchmaker.gd".Lobby] will be returned as the data.
func join_lobby(p_lobby_id: String, p_subscribe: bool = true) -> Request:
	var request = _client.rest.rpc('w4public.lobby_join', {
		lobby_id = p_lobby_id
	})

	var handle_result = func(result):
		if result.is_error():
			return result
		return get_lobby(p_lobby_id, p_subscribe)

	return request.then(handle_result)

## Creates a request to get a lobby. A ["addons/w4gd/matchmaker/matchmaker.gd".Lobby] will be returned as the data.
func get_lobby(p_lobby_id: String, p_subscribe: bool = true) -> Request:
	var request = _client.rest.rpc('w4public.lobby_by_id', {
		lobby_id = p_lobby_id,
	})

	var handle_result = func(result):
		if result.is_error():
			return result

		var lobby = Lobby.new(_client, result.as_dict(), _webrtc_ice_servers, _poll, p_subscribe)

		var subrequests := [
			lobby.refresh_player_list(),
		]
		if lobby.type == LobbyType.WEBRTC_PLAYER_MESH or lobby.type == LobbyType.WEBRTC_PLAYER_HOST or lobby.type == LobbyType.WEBRTC_DEDICATED_SERVER:
			subrequests.append(lobby.refresh_webrtc_sessions())
		else:
			subrequests.append(lobby.refresh_server_ticket())

		var finish_subrequests = func(results):
			for r in results:
				if r.is_error():
					return r
			return PolyResult.new(lobby)

		return Promise.sequence(subrequests).then(finish_subrequests)

	return request.then(handle_result)

## Creates a request to find lobbies that the current player has access to.
##
## This can be useful after restarting the game to see if we can reconnect to an existing match.
##
## [param p_query] is a [Dictionary] that takes the following keys:
## - [code]only_my_lobbies[/code] (bool): If set to true, this will only list lobbies that the current user has joined.
## - [code]include_player_count[/code] (bool): If set to true, this will include [code]player_count[/code] in the result.
## - [code]constraints[/code] ([Dictionary]): A Dictionary of constraints that lobbies must match.
##
## Returns an array of [Dictionary]'s with the following keys:
## - [code]id[/code]
## - [code]type[/code]
## - [code]state[/code]
## - [code]creator_id[/code]
## - [code]props[/code]
## - [code]cluster[/code]
## - [code]created_at[/code]
##
## Usage:
## [codeblock]
## var result = await W4GD.matchmaker.find_lobbies({
##     # Includes a `player_count` for each lobby in the result.
##     include_player_count = true,
##     # Filters to only include lobbies the current user is a member of (as opposed to all lobbies they have access to).
##     only_my_lobbies = true,
##     # Arbitrary constraints on the lobby's columns and properties.
##     constraints = {
##         'type': W4GD.matchmaker.LobbyType.DEDICATED_SERVER,
##         'state': [W4GD.matchmaker.LobbyState.NEW, W4GD.matchmaker.LobbyState.IN_PROGRESS],
##         'player_count': {
##             op = '<',
##             value = 5,
##         },
##         # This is a top-level element inside the JSON of the 'props' column.
##         'props.game-mode': 'battle-royale',
##     },
## }).async()
## [/codeblock]
func find_lobbies(p_query: Dictionary = {}) -> Request:
	if p_query.has('constraints'):
		var full_constraints := {}
		for k in p_query['constraints']:
			var v = p_query['constraints'][k]
			if v is Dictionary:
				full_constraints[k] = v
			elif v is Array:
				full_constraints[k] = {
					op = 'IN',
					value = v,
				}
			else:
				full_constraints[k] = {
					value = v,
				}
		p_query['constraints'] = full_constraints

	var request = _client.rest.rpc('w4public.lobby_find', {query = p_query})

	var handle_result = func(result):
		if result.is_error():
			return result
		# Make the result into an Array of lobbies.
		return PolyResult.new(result.as_dict().get('lobbies', []))

	return request.then(handle_result)


func _subscribe_to_matchmaker_channel() -> void:
	if _matchmaker_channel != null:
		_matchmaker_channel.unsubscribe()
		_matchmaker_channel = null

	if _client.get_identity().is_authenticated():
		var uid = _client.get_identity().get_uid()
		_matchmaker_channel = _client.realtime.channel('matchmaker', { presence = { key = uid }})
		_matchmaker_channel.on_postgres_changes('*', 'w4match.matchmaker_ticket', 'user_id=eq.' + uid)
		_matchmaker_channel.updated.connect(self._on_matchmaker_ticket_updated)
		_matchmaker_channel.deleted.connect(self._on_matchmaker_ticket_updated)
		if await _matchmaker_channel.subscribe() == OK:
			_matchmaker_channel.track({ status = 'connected' })

## Creates a request to join the matchmaker queue.
##
## A ["addons/w4gd/matchmaker/matchmaker.gd".MatchmakerTicket] will be returned as the data.
func join_matchmaker_queue(p_props: Dictionary = {}, p_auto_leave: bool = true) -> Request:
	var request = _client.rest.rpc('w4public.matchmaker_join', {
		props = p_props,
		auto_leave = p_auto_leave,
	})
	return request.then(self._handle_matchmaker_join_result)

func _handle_matchmaker_join_result(p_result: PolyResult) -> PolyResult:
	if p_result.is_error():
		return p_result

	var ticket = _get_or_create_matchmaker_ticket(p_result.ticket_id.as_string())

	# If the ticket already has a lobby, then emit the matched signal after the calling
	# code has had an opportunity to subscribe to it.
	if ticket.lobby_id != "":
		ticket._match.call_deferred(ticket.lobby_id)

	return PolyResult.new(ticket)

func _get_or_create_matchmaker_ticket(p_ticket_id: String, p_lobby_id = null) -> MatchmakerTicket:
	if not _matchmaker_tickets.has(p_ticket_id):
		_matchmaker_tickets[p_ticket_id] = MatchmakerTicket.new(p_ticket_id)
	return _matchmaker_tickets[p_ticket_id]

func _on_matchmaker_ticket_updated(p_data: Dictionary) -> void:
	if p_data['type'] == 'UPDATE':
		var record = p_data['record']
		var ticket = _get_or_create_matchmaker_ticket(record['id'])
		if record['lobby_id'] != null and ticket.lobby_id == "":
			ticket._match(record['lobby_id'])
	elif p_data['type'] == 'DELETE':
		_matchmaker_tickets.erase(p_data['old_record']['id'])

## Creates a request to leave the matchmaker queue.
func leave_matchmaker_queue(p_matchmaker_ticket: MatchmakerTicket) -> Request:
	var request = _client.rest.rpc('w4public.matchmaker_leave', {
		ticket_id = p_matchmaker_ticket.id,
	})
	return request
