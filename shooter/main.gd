extends Node2D

var enemy = preload("res://enemy.tscn")
var score = 0
var playing = false
var wave_index := 0
var kills := 0

@onready var login_screen = $LoginScreen
@onready var start_button = $CanvasLayer/CenterContainer/Start
@onready var game_over = $CanvasLayer/CenterContainer/GameOver

var _backend_status: Label

func _ready():
	_backend_status = Label.new()
	_backend_status.name = "BackendStatus"
	_backend_status.position = Vector2(4, 286)
	_backend_status.size = Vector2(232, 34)
	_backend_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_backend_status.add_theme_font_size_override("font_size", 8)
	_backend_status.text = "Backend: …"
	$CanvasLayer.add_child(_backend_status)
	BackendClient.status_line_changed.connect(_on_backend_status_line)

	login_screen.completed_online.connect(_on_login_flow_done)
	login_screen.completed_offline.connect(_on_login_flow_done)

	await BackendClient.wait_for_bootstrap()
	game_over.hide()
	start_button.hide()
	if BackendClient.jwt.is_empty():
		login_screen.show()
	else:
		login_screen.hide()
		start_button.show()
	var tween = create_tween().set_loops().set_parallel(false).set_trans(Tween.TRANS_SINE)
	tween.tween_property($EnemyAnchor, "position:x", $EnemyAnchor.position.x + 3, 1.0)
	tween.tween_property($EnemyAnchor, "position:x", $EnemyAnchor.position.x - 3, 1.0)
	var tween2 = create_tween().set_loops().set_parallel(false).set_trans(Tween.TRANS_BACK)
	tween2.tween_property($EnemyAnchor, "position:y", $EnemyAnchor.position.y + 3, 1.5).set_ease(Tween.EASE_IN_OUT)
	tween2.tween_property($EnemyAnchor, "position:y", $EnemyAnchor.position.y - 3, 1.5).set_ease(Tween.EASE_IN_OUT)


func _on_backend_status_line(line: String) -> void:
	_backend_status.text = line


func _on_login_flow_done() -> void:
	start_button.show()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_L:
			BackendClient.fetch_leaderboard()


func spawn_enemies():
	wave_index += 1
	for x in range(9):
		for y in range(3):
			var e = enemy.instantiate()
			var pos = Vector2(x * (16 + 8) + 24, 16 * 4 + y * 16)
			add_child(e)
			e.start(pos)
			e.anchor = $EnemyAnchor
			e.died.connect(_on_enemy_died)

func _on_enemy_died(value):
	kills += 1
	score += value
	$CanvasLayer/UI.update_score(score)
	$Camera2D.add_trauma(0.5)

func _process(_delta):
	if get_tree().get_nodes_in_group("enemies").size() == 0 and playing:
		spawn_enemies()

func _on_player_died():
	playing = false
	get_tree().call_group("enemies", "queue_free")
	await BackendClient.submit_game_over(score, wave_index, kills)
	game_over.show()
	await get_tree().create_timer(2).timeout
	game_over.hide()
	start_button.show()

func new_game():
	await BackendClient.wait_for_bootstrap()
	score = 0
	kills = 0
	wave_index = 0
	$CanvasLayer/UI.update_score(score)
	$Player.start()
	await BackendClient.start_session()
	spawn_enemies()
	playing = true

func _on_start_pressed():
	start_button.hide()
	await new_game()
