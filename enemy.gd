extends CharacterBody3D
class_name SmartEnemyAI
#who are we chasing?
@export_group("Target")
@export var target_group: String = "player"
@export var detection_range: float = 35.0           # max detection with los
@export var proximity_range: float = 15.0           # detect without los (can "hear" them)
@export var attack_range: float = 1.8
@export var lose_target_range: float = 45.0
# how fast we move
@export_group("Movement")
@export var walk_speed: float = 3.0
@export var chase_speed: float = 6.0
@export var rotation_speed: float = 12.0
@export var gravity: float = 20.0
# jumping tuning
@export_group("Jumping")
@export var jump_force: float = 10.0
@export var max_jump_height: float = 2.0
@export var min_obstacle_for_jump: float = 0.3
@export var jump_cooldown: float = 0.4
@export var gap_check_distance: float = 2.0
# navigation tuning
@export_group("Navigation")
@export var path_recalc_interval: float = 0.25
@export var obstacle_ray_length: float = 1.5
# states
enum State { IDLE, CHASE, ATTACK, JUMPING }
var current_state: State = State.IDLE
# tracking
var target: Node3D = null
var is_jumping: bool = false
var jump_timer: float = 0.0
var stuck_timer: float = 0.0
var last_position: Vector3 = Vector3.ZERO
var path_recalc_timer: float = 0.0
var move_direction: Vector3 = Vector3.FORWARD
var _nav_map_was_ready: bool = false
var _using_nav: bool = false
# nav agent reference
@onready var nav_agent: NavigationAgent3D = $NavigationAgent3D
func _ready() -> void:
	last_position = global_position
	# hook up avoidance callback
	nav_agent.velocity_computed.connect(Callable(_on_velocity_computed))
func _physics_process(delta: float) -> void:
	# wait for nav map to sync (first frame thing)
	var map_rid = nav_agent.get_navigation_map()
	if map_rid != RID():
		var iter_id = NavigationServer3D.map_get_iteration_id(map_rid)
		if iter_id == 0:
			return
		elif not _nav_map_was_ready:
			_nav_map_was_ready = true
	#gravity
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		if is_jumping:
			is_jumping = false
		velocity.y = 0
	if jump_timer > 0:
		jump_timer -= delta
	# find a target
	_update_target()
	# update nav target periodically
	path_recalc_timer += delta
	if path_recalc_timer >= path_recalc_interval and target:
		path_recalc_timer = 0.0
		nav_agent.target_position = target.global_position
	# state machine
	match current_state:
		State.IDLE:
			_state_idle(delta)
		State.CHASE:
			_state_chase(delta)
		State.ATTACK:
			_state_attack(delta)
		State.JUMPING:
			_state_jumping(delta)

	_check_stuck(delta)
	# move_and_slide always call it here now
	# avoidance callback just updates velocity, we do the slide ourselves
	move_and_slide()
#  state machine
func _state_idle(_delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0, walk_speed * _delta * 5)
	velocity.z = move_toward(velocity.z, 0, walk_speed * _delta * 5)
	if target:
		_change_state(State.CHASE)
func _state_chase(delta: float) -> void:
	if not target:
		_change_state(State.IDLE)
		return
	var distance = global_position.distance_to(target.global_position)
	if distance > lose_target_range:
		target = null
		_change_state(State.IDLE)
		return
	if distance < attack_range:
		_change_state(State.ATTACK)
		return
	# figure out where to move
	# try nav agent first, fall back to direct walk if it fails
	var direct_to_target = global_position.direction_to(target.global_position)
	direct_to_target.y = 0
	direct_to_target = direct_to_target.normalized()
	if not nav_agent.is_navigation_finished():
		var next_point: Vector3 = nav_agent.get_next_path_position()
		var to_next = global_position.direction_to(next_point)
		to_next.y = 0
		var nav_dir = to_next.normalized()
		# check if nav gave us a real direction (not our own position)
		var dist_to_nav_point = global_position.distance_to(next_point)
		if dist_to_nav_point > 0.2 and nav_dir.length() > 0.1:
			# nav is working, use it
			move_direction = nav_dir
			_using_nav = true
		else:
			# nav returned our own position, can't find a path
			# just walk straight toward the player as a fallback
			move_direction = direct_to_target
			_using_nav = false
	else:
		# nav says we are done, but distance says otherwise
		# walk directly toward them
		move_direction = direct_to_target
		_using_nav = false
	# jump checks
	if is_on_floor() and jump_timer <= 0:
		if _should_jump_obstacle():
			_perform_jump(1.0)
			_change_state(State.JUMPING)
			return
		if _should_jump_gap():
			_perform_jump(1.2)
			_change_state(State.JUMPING)
			return
	# apply movement
	if move_direction.length() > 0.1:
		var desired = move_direction * chase_speed

		if nav_agent.avoidance_enabled and _using_nav:
			# let avoidance adjust our velocity
			nav_agent.set_velocity(desired)
		else:
			# go directly either avoidance is off or we're in fallback mode
			velocity.x = desired.x
			velocity.z = desired.z
		# face the direction we're moving
		var target_rot = atan2(move_direction.x, move_direction.z)
		rotation.y = lerp_angle(rotation.y, target_rot, rotation_speed * delta)
func _state_attack(delta: float) -> void:
	velocity.x = move_toward(velocity.x, 0, chase_speed * delta * 5)
	velocity.z = move_toward(velocity.z, 0, chase_speed * delta * 5)
	if not target:
		_change_state(State.IDLE)
		return
	if global_position.distance_to(target.global_position) > attack_range * 1.5:
		_change_state(State.CHASE)
		return
	# keep facing the player
	var to_target = global_position.direction_to(target.global_position)
	to_target.y = 0
	if to_target.length() > 0.1:
		var target_rot = atan2(to_target.x, to_target.z)
		rotation.y = lerp_angle(rotation.y, target_rot, rotation_speed * delta)
func _state_jumping(_delta: float) -> void:
	if move_direction.length() > 0.1:
		velocity.x = move_direction.x * chase_speed * 0.9
		velocity.z = move_direction.z * chase_speed * 0.9
	if is_on_floor() and not is_jumping:
		_change_state(State.CHASE)
func _change_state(new_state: State) -> void:
	if current_state != new_state:
		current_state = new_state
#  avoidance callback
#  nav agent calls this with the safe velocity, we just apply it
#  we don't call move_and_slide here anymore because we do it
#  in _physics_process to keep things simple and avoid double-sliding
func _on_velocity_computed(safe_velocity: Vector3) -> void:
	velocity.x = safe_velocity.x
	velocity.z = safe_velocity.z
#  obstacle & gap detection
func _should_jump_obstacle() -> bool:
	var space = get_world_3d().direct_space_state
	# ray at knee height
	var origin = global_position + Vector3(0, 0.4, 0)
	var end_pos = origin + move_direction * obstacle_ray_length
	var query = PhysicsRayQueryParameters3D.create(origin, end_pos, 1)
	query.exclude = [self]
	var result = space.intersect_ray(query)
	if result:
		# blocked at knee check if head is clear (jumpable)
		var head_origin = global_position + Vector3(0, 1.6, 0)
		var head_end = head_origin + move_direction * obstacle_ray_length
		var head_query = PhysicsRayQueryParameters3D.create(head_origin, head_end, 1)
		head_query.exclude = [self]
		var head_result = space.intersect_ray(head_query)
		if not head_result:
			return true
	return false
func _should_jump_gap() -> bool:
	var space = get_world_3d().direct_space_state
	var check_pos = global_position + move_direction * gap_check_distance
	var origin = check_pos + Vector3(0, 0.3, 0)
	var end_pos = check_pos + Vector3(0, -2.5, 0)
	var query = PhysicsRayQueryParameters3D.create(origin, end_pos, 1)
	query.exclude = [self]
	var result = space.intersect_ray(query)

	return result == null
#  target finding
#  close range: detect by "sound" (no los needed)
#  far range: need line of sight
func _update_target() -> void:
	if target and is_instance_valid(target):
		return
	target = null
	var nodes = get_tree().get_nodes_in_group(target_group)
	var closest_dist = detection_range
	for node in nodes:
		if node is Node3D:
			var dist = global_position.distance_to(node.global_position)
			if dist < closest_dist:
				# close enough to "hear"? skip los check entirely
				if dist <= proximity_range:
					target = node
					closest_dist = dist
				# farther out? need to actually see them
				elif _has_line_of_sight(node):
					target = node
					closest_dist = dist
func _has_line_of_sight(node: Node3D) -> bool:
	var space = get_world_3d().direct_space_state
	var origin = global_position + Vector3(0, 1.0, 0)
	var dest = node.global_position + Vector3(0, 1.0, 0)
	var query = PhysicsRayQueryParameters3D.create(origin, dest, 1)
	query.exclude = [self]
	var result = space.intersect_ray(query)
	if result:
		return result.collider == node or result.collider.get_parent() == node
	return true
#  jumping
func _perform_jump(force_mult: float = 1.0) -> void:
	if is_jumping or not is_on_floor() or jump_timer > 0:
		return
	is_jumping = true
	jump_timer = jump_cooldown
	velocity.y = jump_force * clamp(force_mult, 0.8, 1.4)
#  stuck detection
func _check_stuck(delta: float) -> void:
	var moved = global_position.distance_to(last_position)
	if velocity.length() > 0.5 and is_on_floor() and moved < 0.03:
		stuck_timer += delta
		if stuck_timer > 1.5:
			_handle_stuck()
			stuck_timer = 0.0
	else:
		stuck_timer = 0.0
	last_position = global_position
func _handle_stuck() -> void:
	if is_on_floor() and jump_timer <= 0:
		_perform_jump(1.0)
	var escape = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)).normalized()
	velocity.x = escape.x * chase_speed
	velocity.z = escape.z * chase_speed
