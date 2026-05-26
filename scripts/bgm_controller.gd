extends Node

const BGM_PATH := "res://assets/audio/Mixdown.ogg"

const MENU_START := 0.0
const MENU_END := 103.0
const GAME_INTRO_START := 104.0
const GAME_LOOP_START := 112.0
const GAME_LOOP_END := 238.0

const TRANSITION_SEC := 0.8
const GAME_LOOP_CROSSFADE_SEC := 3.0
const MIN_VOLUME_DB := -60.0
const QUICK_FADE_START_DB := -16.0
const TARGET_VOLUME_DB := 0.0

enum Mode {
	SILENT,
	MENU,
	GAME,
}

var _mode: Mode = Mode.SILENT
var _player: AudioStreamPlayer
var _player_alt: AudioStreamPlayer
var _transition_tween: Tween
var _is_transitioning := false
var _queued_seek := -1.0
var _queued_crossfade := false
var _queued_crossfade_duration := TRANSITION_SEC


func _ready() -> void:
	var stream := load(BGM_PATH) as AudioStream
	_player = AudioStreamPlayer.new()
	_player.name = "BgmPlayerA"
	_player.bus = "Master"
	_player.stream = stream
	_player.volume_db = MIN_VOLUME_DB
	add_child(_player)
	_player_alt = AudioStreamPlayer.new()
	_player_alt.name = "BgmPlayerB"
	_player_alt.bus = "Master"
	_player_alt.stream = stream
	_player_alt.volume_db = MIN_VOLUME_DB
	add_child(_player_alt)
	if stream == null:
		push_warning("BgmController: failed to load stream %s" % BGM_PATH)


func _process(_delta: float) -> void:
	if _player == null or _player.stream == null:
		return
	if _mode == Mode.SILENT:
		return
	if _is_transitioning:
		return
	if not _player.playing:
		return

	var pos := _player.get_playback_position()
	match _mode:
		Mode.MENU:
			if pos >= MENU_END:
				_request_crossfade_seek(MENU_START)
		Mode.GAME:
			if pos >= GAME_LOOP_END:
				_request_crossfade_seek(GAME_LOOP_START, GAME_LOOP_CROSSFADE_SEC)


func play_menu_loop() -> void:
	if _player == null or _player.stream == null:
		return
	_mode = Mode.MENU
	_request_smooth_seek(MENU_START)


func play_game_loop() -> void:
	if _player == null or _player.stream == null:
		return
	_mode = Mode.GAME
	_start_immediate_seek_with_fade_in(GAME_INTRO_START)


func stop_music_smooth() -> void:
	if _player == null or _player.stream == null:
		return
	_mode = Mode.SILENT
	_queued_seek = -1.0
	_queued_crossfade = false
	_queued_crossfade_duration = TRANSITION_SEC
	if _transition_tween != null:
		_transition_tween.kill()
	_transition_tween = create_tween()
	_is_transitioning = true
	_transition_tween.tween_property(_player, "volume_db", MIN_VOLUME_DB, TRANSITION_SEC)
	_transition_tween.tween_callback(Callable(self, "_stop_after_fade"))
	_transition_tween.tween_callback(Callable(self, "_on_transition_complete"))


func _request_smooth_seek(target_sec: float) -> void:
	if _is_transitioning:
		_queued_seek = target_sec
		_queued_crossfade = false
		_queued_crossfade_duration = TRANSITION_SEC
		return
	_start_smooth_seek(target_sec)


func _request_crossfade_seek(target_sec: float, duration_sec: float = TRANSITION_SEC) -> void:
	if _is_transitioning:
		_queued_seek = target_sec
		_queued_crossfade = true
		_queued_crossfade_duration = maxf(duration_sec, 0.01)
		return
	_start_crossfade_seek(target_sec, duration_sec)


func _start_smooth_seek(target_sec: float) -> void:
	if _player == null or _player.stream == null:
		return
	if _player_alt != null:
		_player_alt.stop()
		_player_alt.volume_db = MIN_VOLUME_DB
	if _transition_tween != null:
		_transition_tween.kill()
	_transition_tween = create_tween()
	_is_transitioning = true
	_transition_tween.tween_property(_player, "volume_db", MIN_VOLUME_DB, TRANSITION_SEC * 0.5)
	_transition_tween.tween_callback(Callable(self, "_seek_and_play").bind(target_sec))
	_transition_tween.tween_property(_player, "volume_db", TARGET_VOLUME_DB, TRANSITION_SEC * 0.5)
	_transition_tween.tween_callback(Callable(self, "_on_transition_complete"))


func _start_crossfade_seek(target_sec: float, duration_sec: float = TRANSITION_SEC) -> void:
	if _player == null or _player.stream == null or _player_alt == null:
		return
	if _transition_tween != null:
		_transition_tween.kill()
	duration_sec = maxf(duration_sec, 0.01)
	target_sec = maxf(target_sec, 0.0)
	_player_alt.stop()
	_player_alt.volume_db = MIN_VOLUME_DB
	_player_alt.play(target_sec)
	_transition_tween = create_tween()
	_is_transitioning = true
	_transition_tween.set_parallel(true)
	_transition_tween.tween_property(_player, "volume_db", MIN_VOLUME_DB, duration_sec)
	_transition_tween.tween_property(_player_alt, "volume_db", TARGET_VOLUME_DB, duration_sec)
	_transition_tween.set_parallel(false)
	_transition_tween.tween_callback(Callable(self, "_on_crossfade_complete"))


func _start_immediate_seek_with_fade_in(target_sec: float) -> void:
	if _player == null or _player.stream == null:
		return
	_queued_seek = -1.0
	_queued_crossfade = false
	_queued_crossfade_duration = TRANSITION_SEC
	if _transition_tween != null:
		_transition_tween.kill()
	if _player_alt != null:
		_player_alt.stop()
		_player_alt.volume_db = MIN_VOLUME_DB
	_is_transitioning = true
	target_sec = maxf(target_sec, 0.0)
	_player.volume_db = QUICK_FADE_START_DB
	_player.play(target_sec)
	_transition_tween = create_tween()
	_transition_tween.tween_property(_player, "volume_db", TARGET_VOLUME_DB, TRANSITION_SEC)
	_transition_tween.tween_callback(Callable(self, "_on_transition_complete"))


func _seek_and_play(target_sec: float) -> void:
	if _player == null or _player.stream == null:
		return
	target_sec = maxf(target_sec, 0.0)
	_player.play(target_sec)


func _stop_after_fade() -> void:
	if _player == null:
		return
	_player.stop()
	if _player_alt != null:
		_player_alt.stop()
		_player_alt.volume_db = MIN_VOLUME_DB


func _on_crossfade_complete() -> void:
	if _player_alt == null:
		_on_transition_complete()
		return
	var old_player := _player
	_player = _player_alt
	_player_alt = old_player
	if _player_alt != null:
		_player_alt.stop()
		_player_alt.volume_db = MIN_VOLUME_DB
	_on_transition_complete()


func _on_transition_complete() -> void:
	_is_transitioning = false
	if _mode == Mode.SILENT:
		return
	if _queued_seek >= 0.0:
		var next_seek := _queued_seek
		var use_crossfade := _queued_crossfade
		var crossfade_duration := _queued_crossfade_duration
		_queued_seek = -1.0
		_queued_crossfade = false
		_queued_crossfade_duration = TRANSITION_SEC
		if use_crossfade:
			_start_crossfade_seek(next_seek, crossfade_duration)
		else:
			_start_smooth_seek(next_seek)
