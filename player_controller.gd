extends CharacterBody3D

@export var walk_speed: float = 3.0
@export var sprint_speed: float = 7.0
@export var jump_force: float = 8.0
@export var gravity: float = 20.0
@export var rotation_speed: float = 10.0
@export var crouch_speed: float = 1.5

const SPRINT_ANIM_Y_OFFSET: float = 90.297
const IDLE_DURATION: float = 1.9667
const JUMP_START: float = 0.0
const SPRINT_TURN_START: float = 0.41
const WALK_TURN_START: float = 0.19

const CROUCH_ANIM_Y_OFFSET_START: float = 94.145
const CROUCH_ANIM_Y_OFFSET_END: float = 51.037
const CROUCH_WALK_Y_OFFSET: float = 90.28
const CROUCH_LEGS_CLOSE_RATIO: float = 0.14
const CROUCH_IDLE_FREEZE_RATIO: float = 0.6333
const UNCROUCH_WALK_END: float = 0.31

@onready var character_model: Node3D = $CharacterModel
@onready var ninja: Node3D = $CharacterModel/ninja
@onready var skeleton: Skeleton3D = $CharacterModel/ninja/Skeleton3D
@onready var animation_player: AnimationPlayer = $CharacterModel/ninja/AnimationPlayer
@onready var camera_rig: Node3D = $CameraRig
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var uncrouch_raycast: RayCast3D = $UncrouchRaycast

enum State { IDLE, WALK, SPRINT, JUMP, SPRINT_JUMP, TURNING, CROUCH, CROUCH_WALK }
var current_state: State = State.IDLE
var is_grounded: bool = true
var last_move_direction: Vector3 = Vector3.ZERO
var previous_camera_forward: Vector3 = Vector3.FORWARD
var turn_animation_playing: bool = false
var turn_cooldown: float = 0.0
const TURN_COOLDOWN_TIME: float = 0.5

var current_y_offset: float = 0.0
var target_y_offset: float = 0.0

var jump_windup_active: bool = false
var jump_windup_timer: float = 0.0
const JUMP_LIFTOFF_TIME: float = 0.51

const SPRINT_JUMP_LOOP_START: float = 0.3
const SPRINT_JUMP_LOOP_END: float = 0.64
var sprint_jump_loop_forward: bool = true

var jump_count: int = 0
const MAX_JUMPS: int = 2

var is_crouching: bool = false
var is_uncrouching: bool = false
var can_uncrouch: bool = true
const STANDING_COLLISION_HEIGHT: float = 1.8
const CROUCHING_COLLISION_HEIGHT: float = 1.0

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_play_animation("ninja_idel", "mixamo_com", true)

func _physics_process(delta: float) -> void:
	_ensure_speed_scale_reset()
	
	if jump_windup_active:
		jump_windup_timer += delta
		if jump_windup_timer >= JUMP_LIFTOFF_TIME:
			velocity.y = jump_force
			jump_windup_active = false
			jump_windup_timer = 0.0
	
	if not is_on_floor() and not jump_windup_active:
		velocity.y -= gravity * delta
		is_grounded = false
	elif is_on_floor():
		is_grounded = true
		if not jump_windup_active:
			velocity.y = 0
	
	var input_dir := Vector2.ZERO
	input_dir.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	input_dir.y = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	
	var is_sprinting := Input.is_action_pressed("sprint")
	var wants_jump := Input.is_action_just_pressed("jump")
	var wants_crouch := Input.is_action_just_pressed("crouch")
	
	var camera_forward := -camera_rig.global_transform.basis.z
	camera_forward.y = 0
	camera_forward = camera_forward.normalized()
	
	var camera_right := camera_rig.global_transform.basis.x
	camera_right.y = 0
	camera_right = camera_right.normalized()
	
	var move_direction := (camera_right * input_dir.x + camera_forward * -input_dir.y).normalized()
	
	can_uncrouch = not uncrouch_raycast.is_colliding()
	
	if is_uncrouching:
		_handle_uncrouch_animation()
	elif is_crouching and is_sprinting and can_uncrouch:
		_start_uncrouch(current_state == State.CROUCH_WALK)
	elif wants_crouch and is_grounded:
		if is_crouching and can_uncrouch:
			_start_uncrouch(current_state == State.CROUCH_WALK)
		elif not is_crouching:
			_change_state(State.CROUCH)
	
	if turn_cooldown > 0:
		turn_cooldown -= delta
	
	if not turn_animation_playing and is_grounded and not jump_windup_active and turn_cooldown <= 0 and not is_crouching and not is_uncrouching:
		_check_for_turn(move_direction, is_sprinting)
	
	var current_speed := crouch_speed if is_crouching else (sprint_speed if is_sprinting else walk_speed)
	var is_in_normal_jump := (current_state == State.JUMP or jump_windup_active) and current_state != State.SPRINT_JUMP
	
	if not is_uncrouching:
		if move_direction.length() > 0.1 and not turn_animation_playing and not is_in_normal_jump:
			velocity.x = move_direction.x * current_speed
			velocity.z = move_direction.z * current_speed
			var target_rotation := atan2(move_direction.x, move_direction.z)
			ninja.rotation.y = lerp_angle(ninja.rotation.y, target_rotation, rotation_speed * delta)
			last_move_direction = move_direction
			
			if is_crouching and current_state == State.CROUCH:
				_change_state(State.CROUCH_WALK)
		elif not turn_animation_playing and is_in_normal_jump:
			velocity.x = 0
			velocity.z = 0
		elif not turn_animation_playing:
			velocity.x = move_toward(velocity.x, 0, current_speed)
			velocity.z = move_toward(velocity.z, 0, current_speed)
			
			if is_crouching and current_state == State.CROUCH_WALK and move_direction.length() < 0.1:
				_change_state(State.CROUCH)
	else:
		velocity.x = 0
		velocity.z = 0
	
	var can_sprint_jump := is_sprinting and move_direction.length() > 0.1 and current_state == State.SPRINT_JUMP and jump_count < MAX_JUMPS
	var can_ground_jump := is_grounded and not jump_windup_active and not is_crouching and not is_uncrouching
	
	if is_grounded:
		jump_count = 0
	
	if wants_jump and not turn_animation_playing and not is_crouching and not is_uncrouching:
		if is_sprinting and move_direction.length() > 0.1 and (is_grounded or can_sprint_jump):
			velocity.y = jump_force
			jump_count += 1
			_change_state(State.SPRINT_JUMP)
		elif can_ground_jump:
			jump_windup_active = true
			jump_windup_timer = 0.0
			_change_state(State.JUMP)
	
	if is_grounded and not turn_animation_playing and not jump_windup_active and not is_crouching and not is_uncrouching and current_state != State.JUMP and current_state != State.SPRINT_JUMP:
		if move_direction.length() > 0.1:
			if is_sprinting:
				_change_state(State.SPRINT)
			else:
				_change_state(State.WALK)
		else:
			_change_state(State.IDLE)
	
	_track_crouch_entry_offset()
	ninja.position.y = target_y_offset
	previous_camera_forward = camera_forward
	
	if current_state == State.SPRINT_JUMP and not is_grounded:
		_handle_sprint_jump_loop()
	
	move_and_slide()

func _track_crouch_entry_offset() -> void:
	if current_state != State.CROUCH or is_uncrouching:
		return
	
	var current_anim := animation_player.current_animation
	if not current_anim.begins_with("ninja_crouch"):
		return
	
	if animation_player.speed_scale == 0:
		return
	
	var anim := animation_player.get_animation(current_anim)
	if not anim:
		return
	
	var current_pos := animation_player.current_animation_position
	var legs_close_time := anim.length * CROUCH_LEGS_CLOSE_RATIO
	
	if current_pos >= legs_close_time:
		target_y_offset = CROUCH_ANIM_Y_OFFSET_END

func _play_crouch_frozen(ratio: float) -> void:
	var anim_name := "ninja_crouch/mixamo_com"
	var anim := animation_player.get_animation(anim_name)
	if not anim:
		return
	
	anim.loop_mode = Animation.LOOP_NONE
	animation_player.play(anim_name)
	animation_player.seek(anim.length * ratio)
	animation_player.speed_scale = 0.0

func _ensure_speed_scale_reset() -> void:
	if current_state == State.CROUCH and animation_player.speed_scale == 0.0:
		return
	if not is_uncrouching and current_state != State.SPRINT_JUMP:
		if animation_player.speed_scale != 1.0:
			animation_player.speed_scale = 1.0

func _handle_sprint_jump_loop() -> void:
	var current_anim := animation_player.current_animation
	if current_anim.begins_with("ninja_sprint_jump"):
		var anim := animation_player.get_animation(current_anim)
		if anim:
			var loop_end_time := anim.length * SPRINT_JUMP_LOOP_END
			var loop_start_time := anim.length * SPRINT_JUMP_LOOP_START
			var current_pos := animation_player.current_animation_position
			
			if sprint_jump_loop_forward:
				if current_pos >= loop_end_time:
					sprint_jump_loop_forward = false
					animation_player.speed_scale = -1.0
			else:
				if current_pos <= loop_start_time:
					sprint_jump_loop_forward = true
					animation_player.speed_scale = 1.0
	else:
		sprint_jump_loop_forward = true

func _start_uncrouch(from_walking: bool) -> void:
	if not can_uncrouch or is_uncrouching:
		return
	
	var anim_name := "ninja_crouch/mixamo_com"
	var anim := animation_player.get_animation(anim_name)
	if not anim:
		return
	
	is_uncrouching = true
	is_crouching = false
	
	anim.loop_mode = Animation.LOOP_NONE
	animation_player.play(anim_name)
	animation_player.speed_scale = -1.0
	
	if from_walking:
		animation_player.seek(anim.length * UNCROUCH_WALK_END)
		target_y_offset = CROUCH_ANIM_Y_OFFSET_END
	else:
		animation_player.seek(anim.length * CROUCH_LEGS_CLOSE_RATIO)
		target_y_offset = CROUCH_ANIM_Y_OFFSET_END

func _handle_uncrouch_animation() -> void:
	var current_anim := animation_player.current_animation
	if not current_anim.begins_with("ninja_crouch"):
		_finish_uncrouch()
		return
	
	var anim := animation_player.get_animation(current_anim)
	if not anim:
		_finish_uncrouch()
		return
	
	var current_pos := animation_player.current_animation_position
	var legs_close_time := anim.length * CROUCH_LEGS_CLOSE_RATIO
	
	if current_pos <= legs_close_time and current_pos > 0.1:
		target_y_offset = CROUCH_ANIM_Y_OFFSET_START
	
	if current_pos <= 0.1:
		_finish_uncrouch()

func _finish_uncrouch() -> void:
	is_uncrouching = false
	animation_player.speed_scale = 1.0
	target_y_offset = 0.0
	_set_collision_height(STANDING_COLLISION_HEIGHT)
	current_state = State.IDLE
	_play_animation("ninja_idel", "mixamo_com", true)

func _check_for_turn(move_direction: Vector3, is_sprinting: bool) -> void:
	if last_move_direction.length() < 0.1 or move_direction.length() < 0.1:
		return
	
	var dot := last_move_direction.dot(move_direction)
	
	if dot < -0.5:
		turn_animation_playing = true
		if is_sprinting:
			_change_state(State.TURNING)
			_play_animation_from("ninja_sprint_turn_180", "mixamo_com", SPRINT_TURN_START)
		else:
			_change_state(State.TURNING)
			_play_animation_from("ninja_walk_turn_180", "mixamo_com", WALK_TURN_START)

func _change_state(new_state: State) -> void:
	if current_state == new_state:
		return
	
	var old_state := current_state
	current_state = new_state
	
	match new_state:
		State.IDLE:
			target_y_offset = 0.0
			is_crouching = false
			_set_collision_height(STANDING_COLLISION_HEIGHT)
			_play_animation("ninja_idel", "mixamo_com", true)
		State.WALK:
			target_y_offset = 0.0
			is_crouching = false
			_set_collision_height(STANDING_COLLISION_HEIGHT)
			_play_animation("ninja_walk", "mixamo_com", true)
		State.SPRINT:
			target_y_offset = SPRINT_ANIM_Y_OFFSET
			is_crouching = false
			_set_collision_height(STANDING_COLLISION_HEIGHT)
			_play_animation("ninja_sprint", "mixamo_com", true)
		State.JUMP:
			target_y_offset = 0.0
			_play_animation_from("ninja_jump", "mixamo_com", JUMP_START)
		State.SPRINT_JUMP:
			target_y_offset = SPRINT_ANIM_Y_OFFSET
			_play_animation("ninja_sprint_jump", "mixamo_com", false)
		State.TURNING:
			pass
		State.CROUCH:
			is_crouching = true
			_set_collision_height(CROUCHING_COLLISION_HEIGHT)
			if old_state == State.CROUCH_WALK:
				target_y_offset = CROUCH_ANIM_Y_OFFSET_END
				_play_crouch_frozen(CROUCH_IDLE_FREEZE_RATIO)
			else:
				target_y_offset = CROUCH_ANIM_Y_OFFSET_START
				_play_animation("ninja_crouch", "mixamo_com", false)
		State.CROUCH_WALK:
			is_crouching = true
			target_y_offset = CROUCH_WALK_Y_OFFSET
			_set_collision_height(CROUCHING_COLLISION_HEIGHT)
			_play_animation("ninja_crouch_walking", "mixamo_com", true)

func _set_collision_height(height: float) -> void:
	if collision_shape and collision_shape.shape is CapsuleShape3D:
		collision_shape.shape.height = height
		collision_shape.position.y = height / 2.0

func _play_animation(anim_name: String, library_name: String, loop: bool = false) -> void:
	animation_player.speed_scale = 1.0
	var full_anim_name := anim_name + "/" + library_name
	
	var anim := animation_player.get_animation(full_anim_name)
	if anim:
		if loop:
			anim.loop_mode = Animation.LOOP_LINEAR
		else:
			anim.loop_mode = Animation.LOOP_NONE
	
	if animation_player.current_animation != full_anim_name:
		animation_player.play(full_anim_name)
		if loop:
			if animation_player.animation_finished.is_connected(_on_animation_finished):
				animation_player.animation_finished.disconnect(_on_animation_finished)
		else:
			if not animation_player.animation_finished.is_connected(_on_animation_finished):
				animation_player.animation_finished.connect(_on_animation_finished)

func _play_animation_from(library: String, animation: String, start_time_ratio: float) -> void:
	animation_player.speed_scale = 1.0
	var anim_name := library + "/" + animation
	animation_player.play(anim_name)
	
	var anim_lib := animation_player.get_animation(anim_name)
	if anim_lib:
		var start_pos := anim_lib.length * start_time_ratio
		animation_player.seek(start_pos)
	
	if not animation_player.animation_finished.is_connected(_on_animation_finished):
		animation_player.animation_finished.connect(_on_animation_finished)

func _on_animation_finished(anim_name: StringName) -> void:
	animation_player.speed_scale = 1.0
	
	if turn_animation_playing:
		turn_animation_playing = false
		turn_cooldown = TURN_COOLDOWN_TIME
		var input_dir := Vector2.ZERO
		input_dir.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
		input_dir.y = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
		
		var camera_forward := -camera_rig.global_transform.basis.z
		camera_forward.y = 0
		camera_forward = camera_forward.normalized()
		
		var camera_right := camera_rig.global_transform.basis.x
		camera_right.y = 0
		camera_right = camera_right.normalized()
		
		var current_move_dir := (camera_right * input_dir.x + camera_forward * -input_dir.y).normalized()
		if current_move_dir.length() > 0.1:
			last_move_direction = current_move_dir
		else:
			last_move_direction = -last_move_direction
	
	if current_state == State.JUMP or current_state == State.SPRINT_JUMP or current_state == State.TURNING:
		if velocity.length() > 0.1:
			_change_state(State.WALK)
		else:
			_change_state(State.IDLE)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
