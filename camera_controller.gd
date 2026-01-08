extends Node3D

## Third-Person Camera Controller
## Provides smooth orbit camera with collision avoidance
## Yo bro this was kind of easy but real work was in player_controller.gd
@export var mouse_sensitivity: float = 0.003
@export var follow_speed: float = 8.0
@export var camera_distance: float = 5.0
@export var min_pitch: float = -60.0
@export var max_pitch: float = 45.0

@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D

var yaw: float = 0.0
var pitch: float = -15.0

func _ready() -> void:
	# Configure spring arm
	spring_arm.spring_length = camera_distance
	spring_arm.collision_mask = 1  # Collide with environment
	spring_arm.add_excluded_object(get_parent())
	
	# Apply initial rotation
	_update_camera_rotation()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * mouse_sensitivity
		pitch -= event.relative.y * mouse_sensitivity
		pitch = clamp(pitch, deg_to_rad(min_pitch), deg_to_rad(max_pitch))
		_update_camera_rotation()

func _update_camera_rotation() -> void:
	rotation.y = yaw
	spring_arm.rotation.x = pitch

func _physics_process(delta: float) -> void:
	# Keep camera rig at player position
	var parent := get_parent() as Node3D
	if parent:
		global_position = parent.global_position + Vector3(0, 1.5, 0)
