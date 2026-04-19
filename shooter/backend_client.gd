extends Node
## HTTP client for auth, score, session. URLs: Project Settings → fps/network.
## Defaults target the nginx reverse proxy on :8090 (/api/auth, /api/score, /api/sess). Web export uses window.location.origin + same paths.
## Login screen (default) or dev shortcut: env FPS_EMAIL/FPS_PASSWORD.

signal status_line_changed(line: String)
signal login_succeeded

var jwt: String = ""
var player_id: String = ""
var session_id: String = ""

var bootstrap_done: bool = false
## Set when login/register succeeds; cleared at start of auth attempts.
var last_auth_error: String = ""

var _http: HTTPRequest

var _auth_base: String = ""
var _score_base: String = ""
var _session_base: String = ""


func _ready() -> void:
	if _is_web_export():
		var o := _wasm_page_origin()
		if o.is_empty():
			o = _trim_slash(_setting("fps/network/web_origin_fallback", "http://127.0.0.1:8090"))
		o = _trim_slash(o)
		_auth_base = "%s/api/auth" % o
		_score_base = "%s/api/score" % o
		_session_base = "%s/api/sess" % o
	else:
		_auth_base = _trim_slash(_setting("fps/network/auth_base_url", "http://127.0.0.1:8090/api/auth"))
		_score_base = _trim_slash(_setting("fps/network/score_base_url", "http://127.0.0.1:8090/api/score"))
		_session_base = _trim_slash(_setting("fps/network/session_base_url", "http://127.0.0.1:8090/api/sess"))
	_http = HTTPRequest.new()
	add_child(_http)
	call_deferred("_bootstrap")


func wait_for_bootstrap() -> void:
	while not bootstrap_done:
		await get_tree().process_frame


func _bootstrap() -> void:
	print("BackendClient: APIs auth=%s score=%s session=%s" % [_auth_base, _score_base, _session_base])
	if await try_login_from_env():
		print("BackendClient: logged in via FPS_EMAIL/FPS_PASSWORD")
	var auth_health := await ping_auth_health()
	bootstrap_done = true
	status_line_changed.emit(_compose_status_line(auth_health))
	if jwt.is_empty():
		print(
			"BackendClient: no JWT yet — use the login screen (or FPS_EMAIL/FPS_PASSWORD for dev)."
		)


func _is_web_export() -> bool:
	return OS.has_feature("web") or OS.has_feature("Web")


func _compose_status_line(auth_http_code: int) -> String:
	var bits: PackedStringArray = []
	if jwt.is_empty():
		bits.append("NO LOGIN")
	else:
		bits.append("LOGGED IN")
	if auth_http_code >= 200 and auth_http_code < 300:
		bits.append("auth:%s" % auth_http_code)
	elif auth_http_code >= 0:
		bits.append("auth:ERR %s" % auth_http_code)
	else:
		bits.append("auth:offline")
	return " · ".join(bits)


func ping_auth_health() -> int:
	var err := _http.request(_auth_base.path_join("health"), PackedStringArray(), HTTPClient.METHOD_GET, "")
	if err != OK:
		print("BackendClient: GET /health request err=", err)
		return -1
	print("BackendClient: GET ", _auth_base.path_join("health"))
	var result = await _http.request_completed
	var code: int = result[1]
	print("BackendClient: auth /health -> HTTP ", code)
	return code


func try_login_from_env() -> bool:
	var email := OS.get_environment("FPS_EMAIL")
	var password := OS.get_environment("FPS_PASSWORD")
	if email.is_empty() or password.is_empty():
		return false
	return await login(email, password)



func _wasm_page_origin() -> String:
	var o := ""
	if Engine.has_singleton("JavaScriptBridge"):
		var jb = Engine.get_singleton("JavaScriptBridge")
		var raw = jb.eval("window.location.origin", true)
		if raw != null:
			o = _trim_slash(str(raw))
	if o.is_empty():
		o = _trim_slash(_setting("fps/network/web_origin_fallback", "http://127.0.0.1:8090"))
	return o


func login(email: String, password: String) -> bool:
	last_auth_error = ""
	var payload := JSON.stringify({"email": email, "password": password})
	print("BackendClient: POST ", _auth_base.path_join("login"))
	var err := _http.request(
		_auth_base.path_join("login"),
		_json_headers(),
		HTTPClient.METHOD_POST,
		payload,
	)
	if err != OK:
		last_auth_error = "Request failed (%s)" % err
		push_error("BackendClient.login: request failed (%s)" % err)
		return false
	var result = await _http.request_completed
	return await _finish_auth_success_if_ok(_handle_auth_response(result, "login"))


func register(email: String, password: String) -> bool:
	last_auth_error = ""
	var payload := JSON.stringify({"email": email, "password": password})
	print("BackendClient: POST ", _auth_base.path_join("register"))
	var err := _http.request(
		_auth_base.path_join("register"),
		_json_headers(),
		HTTPClient.METHOD_POST,
		payload,
	)
	if err != OK:
		last_auth_error = "Request failed (%s)" % err
		push_error("BackendClient.register: request failed (%s)" % err)
		return false
	var result = await _http.request_completed
	return await _finish_auth_success_if_ok(_handle_auth_response(result, "register"))


func start_session() -> bool:
	var extra: Array[String] = []
	if not jwt.is_empty():
		extra.append(_bearer_header())
	print("BackendClient: POST ", _session_base.path_join("session/start"))
	var err := _http.request(
		_session_base.path_join("session/start"),
		_json_headers(extra),
		HTTPClient.METHOD_POST,
		"",
	)
	if err != OK:
		push_error("BackendClient.start_session: request failed (%s)" % err)
		return false
	var result = await _http.request_completed
	var parsed := _parse_response_body(result)
	if parsed.is_empty():
		return false
	var sid: Variant = parsed.get("session_id", "")
	if typeof(sid) != TYPE_STRING or (sid as String).is_empty():
		push_error("BackendClient.start_session: missing session_id in response")
		return false
	session_id = sid as String
	return true


func submit_game_over(run_score: int, wave_reached: int, run_kills: int) -> void:
	if not jwt.is_empty():
		var body := JSON.stringify({"score": run_score, "wave_reached": wave_reached})
		var extra: Array[String] = [_bearer_header()]
		var err := _http.request(
			_score_base.path_join("scores"),
			_json_headers(extra),
			HTTPClient.METHOD_POST,
			body,
		)
		if err != OK:
			push_error("BackendClient.submit_game_over scores: request failed (%s)" % err)
		else:
			var r = await _http.request_completed
			_log_http_error(r, "POST /scores")
	if session_id.is_empty():
		push_warning("BackendClient.submit_game_over: no session_id; skipping POST /session/end")
		return
	var end_body := JSON.stringify(
		{
			"session_id": session_id,
			"score": run_score,
			"waves": wave_reached,
			"kills": run_kills,
		}
	)
	var err2 := _http.request(
		_session_base.path_join("session/end"),
		_json_headers(),
		HTTPClient.METHOD_POST,
		end_body,
	)
	if err2 != OK:
		push_error("BackendClient.submit_game_over session/end: request failed (%s)" % err2)
		return
	var r2 = await _http.request_completed
	_log_http_error(r2, "POST /session/end")


func fetch_leaderboard() -> void:
	var err := _http.request(_score_base.path_join("leaderboard"), [], HTTPClient.METHOD_GET, "")
	if err != OK:
		push_error("BackendClient.fetch_leaderboard: request failed (%s)" % err)
		return
	var result = await _http.request_completed
	var code: int = result[1]
	var body: PackedByteArray = result[3]
	print("leaderboard HTTP %s: %s" % [code, body.get_string_from_utf8()])


func _finish_auth_success_if_ok(ok: bool) -> bool:
	if ok:
		login_succeeded.emit()
		var h := await ping_auth_health()
		status_line_changed.emit(_compose_status_line(h))
	return ok


func _handle_auth_response(result: Array, ctx: String) -> bool:
	var code: int = result[1]
	var body: PackedByteArray = result[3]
	var text := body.get_string_from_utf8()
	last_auth_error = ""
	var data = JSON.parse_string(text)
	var parsed: Dictionary = {}
	if typeof(data) == TYPE_DICTIONARY:
		parsed = data
	if code < 200 or code >= 300:
		last_auth_error = _extract_server_error(parsed, text)
		push_warning("BackendClient.%s HTTP %s: %s" % [ctx, code, text])
		return false
	var token: Variant = parsed.get("token", "")
	var pid: Variant = parsed.get("player_id", "")
	if typeof(token) != TYPE_STRING or (token as String).is_empty():
		last_auth_error = "No token in response"
		push_error("BackendClient.%s: no token in response" % ctx)
		return false
	jwt = token as String
	player_id = str(pid) if pid != null else ""
	print("BackendClient: logged in player_id=%s" % player_id)
	return true


func _extract_server_error(parsed: Dictionary, raw_text: String) -> String:
	if not parsed.is_empty():
		var msg = str(parsed.get("message", "")).strip_edges()
		var err = str(parsed.get("error", "")).strip_edges()
		if not msg.is_empty():
			return msg
		if not err.is_empty():
			return err
	return raw_text


func _parse_response_body(result: Array) -> Dictionary:
	var code: int = result[1]
	var body: PackedByteArray = result[3]
	var text := body.get_string_from_utf8()
	if code < 200 or code >= 300:
		push_warning("BackendClient HTTP %s: %s" % [code, text])
		return {}
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("BackendClient: expected JSON object, got %s" % typeof(data))
		return {}
	return data


func _log_http_error(result: Array, label: String) -> void:
	var code: int = result[1]
	var body: PackedByteArray = result[3]
	if code < 200 or code >= 300:
		push_warning("%s HTTP %s: %s" % [label, code, body.get_string_from_utf8()])


func _json_headers(extra: Array[String] = []) -> PackedStringArray:
	var headers := PackedStringArray(["Content-Type: application/json"])
	for x in extra:
		headers.append(x)
	return headers


func _bearer_header() -> String:
	return "Authorization: Bearer %s" % jwt


func _setting(key: String, fallback: String) -> String:
	if ProjectSettings.has_setting(key):
		return str(ProjectSettings.get_setting(key))
	return fallback


func _trim_slash(s: String) -> String:
	while s.ends_with("/"):
		s = s.substr(0, s.length() - 1)
	return s
