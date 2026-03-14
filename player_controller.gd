extends CharacterBody3D
@export var walk_speed: float = 3.0
@export var sprint_speed: float = 7.0
@export var jump_force: float = 8.0
@export var gravity: float = 20.0
@export var rotation_speed: float = 10.0
@export var crouch_speed: float = 1.5
# y-offsets to align the ninja mesh with the ground during different anims
const SPRINT_ANIM_Y_OFFSET: float = 90.297
const CROUCH_ANIM_Y_OFFSET_START: float = 94.145
const CROUCH_ANIM_Y_OFFSET_END: float = 51.037
const CROUCH_WALK_Y_OFFSET: float = 90.28
# animation timing constants these are ratios of the anim length
const JUMP_START: float = 0.0
const CROUCH_LEGS_CLOSE_RATIO: float = 0.14
const CROUCH_IDLE_FREEZE_RATIO: float = 0.6333
const UNCROUCH_WALK_END: float = 0.31
# sprint jump loops between these two points while airborne
const SPRINT_JUMP_LOOP_START: float = 0.3
const SPRINT_JUMP_LOOP_END: float = 0.64
# collision capsule sizes
const STANDING_COLLISION_HEIGHT: float = 1.8
const CROUCHING_COLLISION_HEIGHT: float = 1.0
# landing detection raycast checks ground proximity while airborne
const LANDING_DETECT_DISTANCE: float = 0.1
const GROUND_RAY_LENGTH: float = 5.0
# the jump anim plays a windup before the character actually leaves the ground
const JUMP_LIFTOFF_TIME: float = 0.51
const MAX_JUMPS: int = 2
# node references
@onready var ninja: Node3D = $CharacterModel/ninja
@onready var animation_player: AnimationPlayer = $CharacterModel/ninja/AnimationPlayer
@onready var camera_rig: Node3D = $CameraRig
@onready var collision_shape: CollisionShape3D = $CollisionShape3D
@onready var uncrouch_raycast: RayCast3D = $UncrouchRaycast
enum State { IDLE, WALK, SPRINT, JUMP, SPRINT_JUMP, CROUCH, CROUCH_WALK }
var current_state: State = State.IDLE
var is_grounded: bool = true
var last_move_direction: Vector3 = Vector3.ZERO
var previous_camera_forward: Vector3 = Vector3.FORWARD
var target_y_offset: float = 0.0
# 180 reversal detection
var reverse_dot_threshold: float = -0.5
var reversal_rotation_speed: float = 10.0
var _reversing: bool = false
var _reversal_target_rot: float = 0.0
# jump windup normal jump has a short anim delay before liftoff
var jump_windup_active: bool = false
var jump_windup_timer: float = 0.0
var sprint_jump_loop_forward: bool = true
var jump_count: int = 0
# crouching
var is_crouching: bool = false
var is_uncrouching: bool = false
var can_uncrouch: bool = true
# landing detection
var _landing_triggered: bool = false
# wind burst effect for multijumps
var _wind_particles: GPUParticles3D = null
func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	_play_animation("ninja_idel", "mixamo_com", true)
	_setup_wind_particles()
func _physics_process(delta: float) -> void:
	_ensure_speed_scale_reset()
	# jump windup wait for the anim to play before actually jumping
	if jump_windup_active:
		jump_windup_timer += delta
		if jump_windup_timer >= JUMP_LIFTOFF_TIME:
			velocity.y = jump_force
			jump_windup_active = false
			jump_windup_timer = 0.0
	# gravity
	if not is_on_floor() and not jump_windup_active:
		velocity.y -= gravity * delta
		is_grounded = false
	elif is_on_floor():
		is_grounded = true
		_landing_triggered = false
		if not jump_windup_active:
			velocity.y = 0
	# read input
	var input_dir := Vector2.ZERO
	input_dir.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	input_dir.y = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	var is_sprinting := Input.is_action_pressed("sprint")
	var wants_jump := Input.is_action_just_pressed("jump")
	var wants_crouch := Input.is_action_just_pressed("crouch")
	# get camera-relative directions
	var camera_forward := -camera_rig.global_transform.basis.z
	camera_forward.y = 0
	camera_forward = camera_forward.normalized()
	var camera_right := camera_rig.global_transform.basis.x
	camera_right.y = 0
	camera_right = camera_right.normalized()
	var move_direction := (camera_right * input_dir.x + camera_forward * -input_dir.y).normalized()
	# check if there's room to stand up
	can_uncrouch = not uncrouch_raycast.is_colliding()
	# crouch toggle / sprint-to-uncrouch
	if is_uncrouching:
		_handle_uncrouch_animation()
	elif is_crouching and is_sprinting and can_uncrouch:
		_start_uncrouch(current_state == State.CROUCH_WALK)
	elif wants_crouch and is_grounded:
		if is_crouching and can_uncrouch:
			_start_uncrouch(current_state == State.CROUCH_WALK)
		elif not is_crouching:
			_change_state(State.CROUCH)
	# check for 180 reversal smooth rotation and keep walking
	if is_grounded and not jump_windup_active and not is_crouching and not is_uncrouching:
		_check_for_reversal(move_direction)
	_process_reversal(delta)
	var current_speed := crouch_speed if is_crouching else (sprint_speed if is_sprinting else walk_speed)
	var is_in_normal_jump := (current_state == State.JUMP or jump_windup_active) and current_state != State.SPRINT_JUMP
	# movement
	if not is_uncrouching:
		if move_direction.length() > 0.1 and not is_in_normal_jump:
			velocity.x = move_direction.x * current_speed
			velocity.z = move_direction.z * current_speed
			var target_rotation := atan2(move_direction.x, move_direction.z)
			ninja.rotation.y = lerp_angle(ninja.rotation.y, target_rotation, rotation_speed * delta)
			last_move_direction = move_direction
			if is_crouching and current_state == State.CROUCH:
				_change_state(State.CROUCH_WALK)
		elif is_in_normal_jump:
			#give a tiny bit of air control instead of freezing completely
			velocity.x = move_toward(velocity.x, 0, walk_speed * delta * 2)
			velocity.z = move_toward(velocity.z, 0, walk_speed * delta * 2)
		else:
			#  scale deceleration by delta so it's framerate-independent
			velocity.x = move_toward(velocity.x, 0, current_speed * delta * 10)
			velocity.z = move_toward(velocity.z, 0, current_speed * delta * 10)
			if is_crouching and current_state == State.CROUCH_WALK and move_direction.length() < 0.1:
				_change_state(State.CROUCH)
	else:
		velocity.x = 0
		velocity.z = 0
	# jumping
	var can_sprint_jump := is_sprinting and move_direction.length() > 0.1 and current_state == State.SPRINT_JUMP and jump_count < MAX_JUMPS
	var can_ground_jump := is_grounded and not jump_windup_active and not is_crouching and not is_uncrouching
	if wants_jump and not is_crouching and not is_uncrouching:
		if is_sprinting and move_direction.length() > 0.1 and (is_grounded or can_sprint_jump):
			velocity.y = jump_force
			jump_count += 1
			if jump_count >= 2:
				_emit_wind_burst()
			_change_state(State.SPRINT_JUMP)
		elif can_ground_jump:
			jump_windup_active = true
			jump_windup_timer = 0.0
			_change_state(State.JUMP)
	# reset jump count when grounded and not in a jump state
	# (avoids resetting on the same frame as takeoff since is_on_floor is still true)
	if is_grounded and current_state != State.SPRINT_JUMP and current_state != State.JUMP:
		jump_count = 0
	# state transitions on ground
	if is_grounded and not jump_windup_active and not is_crouching and not is_uncrouching and current_state != State.JUMP and current_state != State.SPRINT_JUMP:
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
	# loop sprint jump anim while airborne
	if current_state == State.SPRINT_JUMP and not is_grounded and not _landing_triggered:
		_handle_sprint_jump_loop()
	# check if we're about to land — transition early for smooth feel
	_check_landing_proximity()
	move_and_slide()
# crouch animation helpers
func _track_crouch_entry_offset() -> void:
	# during the crouch entry anim, snap the y-offset once legs close
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
	# freeze the crouch anim at a specific frame (used for crouch idle)
	var anim_name := "ninja_crouch/mixamo_com"
	var anim := animation_player.get_animation(anim_name)
	if not anim:
		return
	anim.loop_mode = Animation.LOOP_NONE
	animation_player.play(anim_name)
	animation_player.seek(anim.length * ratio)
	animation_player.speed_scale = 0.0
func _start_uncrouch(from_walking: bool) -> void:
	if not can_uncrouch or is_uncrouching:
		return
	var anim_name := "ninja_crouch/mixamo_com"
	var anim := animation_player.get_animation(anim_name)
	if not anim:
		return
	is_uncrouching = true
	is_crouching = false
	# play the crouch anim in reverse to stand up
	anim.loop_mode = Animation.LOOP_NONE
	animation_player.play(anim_name)
	animation_player.speed_scale = -1.0
	if from_walking:
		animation_player.seek(anim.length * UNCROUCH_WALK_END)
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
# speed scale safety
func _ensure_speed_scale_reset() -> void:
	# some states need speed_scale = 0 or -1, make sure we reset when not in those states
	if current_state == State.CROUCH and animation_player.speed_scale == 0.0:
		return
	if not is_uncrouching and current_state != State.SPRINT_JUMP:
		if animation_player.speed_scale != 1.0:
			animation_player.speed_scale = 1.0
# sprint jump loop
func _handle_sprint_jump_loop() -> void:
	# ping-pong the sprint jump anim between two keyframes while airborne
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
# wind burst effect for multijumps
func _setup_wind_particles() -> void:
	_wind_particles = GPUParticles3D.new()
	_wind_particles.emitting = false
	_wind_particles.one_shot = true
	_wind_particles.amount = 24
	_wind_particles.lifetime = 0.4
	_wind_particles.explosiveness = 1.0
	_wind_particles.visibility_aabb = AABB(Vector3(-3, -1, -3), Vector3(6, 2, 6))
	# particle material
	var mat := ParticleProcessMaterial.new()
	# emit in a ring shape outward from center
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	mat.emission_ring_radius = 0.5
	mat.emission_ring_inner_radius = 0.1
	mat.emission_ring_height = 0.05
	mat.emission_ring_axis = Vector3(0, 1, 0)
	# particles shoot outward and slightly down
	mat.direction = Vector3(0, -0.3, 0)
	mat.spread = 80.0
	mat.initial_velocity_min = 2.0
	mat.initial_velocity_max = 4.0
	mat.gravity = Vector3(0, -1.0, 0)
	# size: start visible, shrink to nothing
	mat.scale_min = 0.08
	mat.scale_max = 0.15
	var scale_curve := CurveTexture.new()
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 1.0))
	curve.add_point(Vector2(0.5, 0.6))
	curve.add_point(Vector2(1.0, 0.0))
	scale_curve.curve = curve
	mat.scale_curve = scale_curve
	# fade: white-blue to transparent
	mat.color = Color(0.85, 0.92, 1.0, 0.7)
	var color_ramp := GradientTexture1D.new()
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.9, 0.95, 1.0, 0.8))
	gradient.add_point(0.5, Color(0.7, 0.85, 1.0, 0.4))
	gradient.set_color(1, Color(0.6, 0.8, 1.0, 0.0))
	color_ramp.gradient = gradient
	mat.color_ramp = color_ramp
	_wind_particles.process_material = mat
	# mesh for each particle small flat quad
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.3, 0.3)
	var mesh_mat := StandardMaterial3D.new()
	mesh_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mesh_mat.vertex_color_use_as_albedo = true
	mesh_mat.albedo_color = Color(1, 1, 1, 1)
	mesh.material = mesh_mat
	_wind_particles.draw_pass_1 = mesh
	add_child(_wind_particles)
func _emit_wind_burst() -> void:
	if not _wind_particles:
		return
	# position at the player's feet
	_wind_particles.global_position = global_position + Vector3(0, 0.05, 0)
	_wind_particles.emitting = false
	_wind_particles.emitting = true
# landing detection
func _check_landing_proximity() -> void:
	# only check while airborne in a jump state and falling
	if is_grounded or _landing_triggered:
		return
	if current_state != State.JUMP and current_state != State.SPRINT_JUMP:
		return
	if velocity.y >= 0:
		return
	# cast a ray straight down to find the ground
	var space := get_world_3d().direct_space_state
	var origin := global_position
	var end_pos := origin + Vector3(0, -GROUND_RAY_LENGTH, 0)
	var query := PhysicsRayQueryParameters3D.create(origin, end_pos, 1)
	query.exclude = [get_rid()]
	var result := space.intersect_ray(query)
	if not result:
		return
	var ground_distance: float = origin.y - result.position.y
	if ground_distance > LANDING_DETECT_DISTANCE:
		return
	# ground is close, transition based on current input
	_landing_triggered = true
	sprint_jump_loop_forward = true
	animation_player.speed_scale = 1.0
	var is_sprinting := Input.is_action_pressed("sprint")
	var input_dir := Vector2.ZERO
	input_dir.x = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	input_dir.y = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	var has_input := input_dir.length() > 0.1
	if has_input and is_sprinting:
		_change_state(State.SPRINT)
	elif has_input:
		_change_state(State.WALK)
	else:
		_change_state(State.IDLE)
# 180 reversal detection, yo mikel i removed the reverse animation and made a custom method the animation which we used before was not good 
func _check_for_reversal(move_direction: Vector3) -> void:
	if last_move_direction.length() < 0.1 or move_direction.length() < 0.1:
		return
	# if the new direction is roughly opposite, start a smooth reversal
	var dot := last_move_direction.dot(move_direction)
	if dot < reverse_dot_threshold and not _reversing:
		_reversing = true
		_reversal_target_rot = atan2(move_direction.x, move_direction.z)
		last_move_direction = move_direction

# called every frame from _physics_process to smoothly lerp during a reversal
func _process_reversal(delta: float) -> void:
	if not _reversing:
		return
	ninja.rotation.y = lerp_angle(ninja.rotation.y, _reversal_target_rot, reversal_rotation_speed * delta)
	# finish when close enough
	if abs(angle_difference(ninja.rotation.y, _reversal_target_rot)) < 0.05:
		ninja.rotation.y = _reversal_target_rot
		_reversing = false
#state machine
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
#animation helpers
func _play_animation(anim_name: String, library_name: String, loop: bool = false) -> void:
	animation_player.speed_scale = 1.0
	var full_anim_name := anim_name + "/" + library_name
	var anim := animation_player.get_animation(full_anim_name)
	if anim:
		anim.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
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
		animation_player.seek(anim_lib.length * start_time_ratio)
	if not animation_player.animation_finished.is_connected(_on_animation_finished):
		animation_player.animation_finished.connect(_on_animation_finished)
func _on_animation_finished(anim_name: StringName) -> void:
	animation_player.speed_scale = 1.0
	# after jump, go back to walk or idle
	if current_state == State.JUMP or current_state == State.SPRINT_JUMP:
		if velocity.length() > 0.1:
			_change_state(State.WALK)
		else:
			_change_state(State.IDLE)
func _input(event: InputEvent) -> void:
	# escape toggles mouse capture
	if event.is_action_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
