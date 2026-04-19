extends CanvasLayer
## Blocks until the player logs in, registers, or chooses offline play.

signal completed_online
signal completed_offline

@onready var _email: LineEdit = $CenterContainer/VBoxContainer/EmailField
@onready var _password: LineEdit = $CenterContainer/VBoxContainer/PasswordField
@onready var _error: Label = $CenterContainer/VBoxContainer/ErrorLabel


func _ready() -> void:
	_password.secret = true
	clear_error()


func clear_error() -> void:
	_error.text = ""


func _on_login_pressed() -> void:
	clear_error()
	var email := _email.text.strip_edges()
	var password := _password.text
	if email.is_empty() or password.is_empty():
		_error.text = "Enter email and password."
		return
	var ok := await BackendClient.login(email, password)
	if ok:
		hide()
		completed_online.emit()
	else:
		var msg := BackendClient.last_auth_error
		_error.text = msg if not msg.is_empty() else "Login failed."


func _on_register_pressed() -> void:
	clear_error()
	var email := _email.text.strip_edges()
	var password := _password.text
	if email.is_empty() or password.is_empty():
		_error.text = "Enter email and password."
		return
	if password.length() < 8:
		_error.text = "Password must be at least 8 characters."
		return
	var ok := await BackendClient.register(email, password)
	if ok:
		hide()
		completed_online.emit()
	else:
		var msg := BackendClient.last_auth_error
		_error.text = msg if not msg.is_empty() else "Register failed."


func _on_offline_pressed() -> void:
	clear_error()
	hide()
	completed_offline.emit()
