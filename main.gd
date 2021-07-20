class_name Main
extends Spatial


enum LeftClickAction {
	SELECT,
	MOVE_SELECTED,
	ROTATE_SELECTED,
	PING,
}

const mouse_speed: float = 0.003
const camera_speed_mod: float = .1
const zoom_speed: float = 0.5
const ray_length: float = 1000.0
const speed: float = 10.0
const tile_types = {
	"floor": 0,
	"door": 1,
	"hiddendoor": 1,
	"stairsup": 7,
	"stairsdown": 6,
	"start": 8,
}
const ignored_characters = ["A", " "]
const DRAW_HEIGHT: float = 0.1
const DRAW_WIDTH: float = 0.5

var right_mouse_button_pressed: bool = false
var left_click_action: int = LeftClickAction.SELECT
var selected_piece: Piece = null
var return_selected_to_saved_position: bool = false
var draw_material: SpatialMaterial = SpatialMaterial.new()

var is_popup_showing := false
var should_draw_walls := true

var minis = {}
var lines = {}
var circles = {}
var rectangles = {}

# [style, tile_size, rotation_offset, name_height, filename] 
var models = [
	["Paladin", 1, 270, 2.6, "paladin.tres"],
	["Explorer", 1, 270, 2.4, "explorer.tres"],
	["Monster", 1, 270, 2.4, "monster.tres"],
	["Big Monster", 2, 270, 3.2, "bigmonster.tres"],
	["Avallach", 1, 270, 2.6, "avallach.tres"],
	["Lelyvia", 1, 270, 2.6, "lelyvia.tres"],
]

var tile_rotations = [0, 10, 16, 22]
var current_floor: int = 0

var shared_sparse_map = {}
var full_sparse_map = {}
# A list of all tile locations in a given room
var rooms = []
# A client side sparse list of rooms
var shared_rooms = {}

const ping_scene = preload("res://ping.tscn")
const mini_scene = preload("res://mini.tscn")
const circle_aoe_scene = preload("res://circle_aoe.tscn")
const rectangle_aoe_scene = preload("res://rectangle_aoe.tscn")


func _ready():
	if Network.connect('player_connected', self, '_on_Network_player_connected') != OK:
		print("Failed to connect \"player_connected\"")
	$GameMenu.hide()
	$MainMenu.show()
	draw_material.flags_unshaded = true
	draw_material.flags_use_point_size = true
	draw_material.albedo_color = Color.red


func _unhandled_input(event):
	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.scancode == KEY_ESCAPE:
				change_left_click_action(LeftClickAction.SELECT)
			if event.scancode == KEY_SPACE:
				cycle_movement_action()
			if event.scancode == KEY_TAB:
				Snap.cycle_move_mode()
				$GameMenu.update_snap_mode()
	if event is InputEventMouseButton:
		if event.pressed:
			if event.button_index == BUTTON_WHEEL_UP:
				$camera_origin/camera_pitch/camera.translation.z -= zoom_speed
				if ($camera_origin/camera_pitch/camera.translation.z < 0):
					$camera_origin/camera_pitch/camera.translation.z = 0
			elif event.button_index == BUTTON_WHEEL_DOWN:
				$camera_origin/camera_pitch/camera.translation.z += zoom_speed
			elif event.button_index == BUTTON_RIGHT:
				right_mouse_button_pressed = true
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			elif event.button_index == BUTTON_LEFT:
				var floor_target = get_mouse_floor_intersection(event.position)
				match left_click_action:
					LeftClickAction.SELECT:
#						print("executing LeftClickAction.SELECT")
						var camera = $camera_origin/camera_pitch/camera
						var start_coordinate = camera.project_ray_origin(event.position)
						var end_coordinate = start_coordinate + camera.project_ray_normal(event.position) * ray_length
						var space_state = get_world().direct_space_state
						var result = space_state.intersect_ray(start_coordinate, end_coordinate)
						if result:
							if result.collider.has_method("set_selected"):
								select_piece(result.collider)
								change_left_click_action(LeftClickAction.MOVE_SELECTED)
					LeftClickAction.MOVE_SELECTED:
#						print("executing LeftClickAction.MOVE_SELECTED")
						assert(selected_piece != null)
						if floor_target != null:
							var local_snap_mode: int = get_snap_mode_if_auto()
							var snapped_position: Vector3 = compute_snap_position(floor_target, local_snap_mode)
							selected_piece.move_to_remote(snapped_position, current_floor)
							return_selected_to_saved_position = false
							change_left_click_action(LeftClickAction.SELECT)
							redraw_gridmap_tiles()
					LeftClickAction.ROTATE_SELECTED:
#						print("executing LeftClickAction.ROTATE_SELECTED")
						assert(selected_piece != null)
						if floor_target != null:
							var selected_position := selected_piece.global_transform.origin
							var target_direction: Vector3 = floor_target - selected_position
							selected_piece.rotate_to(compute_snap_direction(target_direction))
							change_left_click_action(LeftClickAction.SELECT)
					LeftClickAction.PING:
#						print("executing LeftClickAction.PING")
						rpc("ping_NETWORK", floor_target)
					_:
						print("tried to execute invalid LeftClickAction")
						assert(true)
		else:
			if event.button_index == BUTTON_RIGHT:
				right_mouse_button_pressed = false
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif event is InputEventMouseMotion:
		if right_mouse_button_pressed:
			# Horizontal Movement
			$camera_origin.rotate(Vector3(0,1,0), -event.relative.x * mouse_speed)

			# Bounded Vertical Movement
			var x_rotate_distance = -event.relative.y * mouse_speed
			if $camera_origin/camera_pitch.rotation.x + x_rotate_distance >= PI/2:
				x_rotate_distance = PI/2 - $camera_origin/camera_pitch.rotation.x
			if $camera_origin/camera_pitch.rotation.x + x_rotate_distance <= -PI/2:
				x_rotate_distance = -PI/2 - $camera_origin/camera_pitch.rotation.x
			$camera_origin/camera_pitch.rotate_object_local(Vector3(1,0,0), x_rotate_distance)


func _process(delta):
	if !get_tree().has_network_peer():
		return

	var strafe_left = Input.is_action_pressed("ui_left");
	var strafe_right = Input.is_action_pressed("ui_right");
	var move_foward = Input.is_action_pressed("ui_up");
	var move_backward = Input.is_action_pressed("ui_down");

	var local_direction = Vector2(0,0)

	if move_foward:
		local_direction += Vector2(-1,0)
	if strafe_left:
		local_direction += Vector2(0,-1)
	if strafe_right:
		local_direction += Vector2(0,1)
	if move_backward:
		local_direction += Vector2(1,0)

	if local_direction != Vector2(0,0)  && !is_popup_showing:
		var velocity = local_direction.normalized().rotated($camera_origin.rotation.y) * ($camera_origin/camera_pitch/camera.translation.z*camera_speed_mod+1) * speed * delta
		$camera_origin.translation.x += velocity.y
		$camera_origin.translation.z += velocity.x

	if get_tree().is_network_server():
		var x = int(floor($camera_origin.translation.x/2))
		var y = int(floor($camera_origin.translation.z/2))
		var z = current_floor

		var shared_tile = sparse_map_lookup(shared_sparse_map,x,y,z)
		var full_tile = sparse_map_lookup(full_sparse_map,x,y,z)

		if shared_tile != null && shared_tile.hidden:
			$GameMenu.set_unhide_tile_disabled(false)
		else:
			$GameMenu.set_unhide_tile_disabled(true)

		var should_disable_share_button = true

		if full_tile != null:
			for room in full_tile.rooms:
				if !shared_rooms.has(room):
					should_disable_share_button = false

		$GameMenu.set_share_room_disabled(should_disable_share_button)

	match left_click_action:
		LeftClickAction.MOVE_SELECTED:
			assert(selected_piece != null)
			var local_snap_mode: int = get_snap_mode_if_auto()
			var mouse_floor_intersection = get_mouse_floor_intersection(get_viewport().get_mouse_position())
			if mouse_floor_intersection != null:
				var snapped_position: Vector3 = compute_snap_position(mouse_floor_intersection, local_snap_mode)
				selected_piece.set_location_local(snapped_position, current_floor)
			else:
				selected_piece.return_to_saved_position()
			draw_snap_position(selected_piece.saved_position, local_snap_mode)
		LeftClickAction.ROTATE_SELECTED:
			assert(selected_piece != null)
			var mouse_floor_intersection = get_mouse_floor_intersection(get_viewport().get_mouse_position())
			if mouse_floor_intersection != null:
				var selected_position = selected_piece.global_transform.origin
				var selected_direction = selected_piece.global_transform.basis.z
				var target_direction: Vector3 = mouse_floor_intersection - selected_position
				var snap_direction := compute_snap_direction(target_direction)

				selected_position.y = DRAW_HEIGHT
				var draw_node = get_node("Draw")
				draw_node.set_material_override(draw_material)
				draw_node.clear()
				draw_node.begin(Mesh.PRIMITIVE_LINES, null)
				# Draw small vertical line at intersection
				draw_node.add_vertex(mouse_floor_intersection)
				draw_node.add_vertex(mouse_floor_intersection + Vector3(0,1,0))
				# Draw line from selected object towards intersection
				draw_node.add_vertex(selected_position)
				draw_node.add_vertex(selected_position + snap_direction * 3)
				# Draw facing direction of selected object
				draw_node.add_vertex(selected_position)
				draw_node.add_vertex(selected_position + selected_direction * 2)
				draw_node.end()


func change_left_click_action(new_action: int) -> void:
	if new_action == left_click_action:
		return

	# Run logic when exiting the current action
	match left_click_action:
#		LeftClickAction.SELECT:
#			print("exiting LeftClickAction.SELECT")
		LeftClickAction.MOVE_SELECTED:
#			print("exiting LeftClickAction.MOVE_SELECTED")
			if return_selected_to_saved_position:
				selected_piece.return_to_saved_position()
			var draw_node = get_node("Draw")
			draw_node.set_material_override(draw_material)
			draw_node.clear()
			draw_node.end()
			if new_action != LeftClickAction.ROTATE_SELECTED:
				deselect_piece()
		LeftClickAction.ROTATE_SELECTED:
#			print("exiting LeftClickAction.ROTATE_SELECTED")
			var draw_node = get_node("Draw")
			draw_node.set_material_override(draw_material)
			draw_node.clear()
			draw_node.end()
			if new_action != LeftClickAction.MOVE_SELECTED:
				deselect_piece()
		LeftClickAction.PING:
#			print("exiting LeftClickAction.PING")
			$GameMenu.set_ping_pressed(false)

	# Change the current action
	left_click_action = new_action

	# Run logic when entering the new action
	match left_click_action:
#		LeftClickAction.SELECT:
#			print("entering LeftClickAction.SELECT")
		LeftClickAction.MOVE_SELECTED:
#			print("entering LeftClickAction.MOVE_SELECTED")
			selected_piece.save_current_position()
			return_selected_to_saved_position = true
#		LeftClickAction.ROTATE_SELECTED:
#			print("entering LeftClickAction.ROTATE_SELECTED")
#		LeftClickAction.PING:
#			print("entering LeftClickAction.PING")


func cycle_movement_action() -> void:
	# Only cycles the LeftCLickAction's that pertain to object movement
	# i.e. Not PING or SELECT
	match left_click_action:
		LeftClickAction.MOVE_SELECTED:
			change_left_click_action(LeftClickAction.ROTATE_SELECTED)
		LeftClickAction.ROTATE_SELECTED:
			change_left_click_action(LeftClickAction.MOVE_SELECTED)


func get_snap_mode_if_auto():
	if Snap.move_mode == Snap.MoveMode.AUTO:
		return get_auto_snap_mode(selected_piece.tile_size_x, selected_piece.tile_size_z)
	return Snap.move_mode


func get_auto_snap_mode(x: int, z: int) -> int:
	var auto_snap_mode: int
	if x % 2 == 0:
		if z % 2 == 0:
			auto_snap_mode = Snap.MoveMode.CORNER
		else:
			auto_snap_mode = Snap.MoveMode.EDGE_Z
	else:
		if z % 2 == 0:
			auto_snap_mode = Snap.MoveMode.EDGE_X
		else:
			auto_snap_mode = Snap.MoveMode.CENTER
	return auto_snap_mode


func tile_center(value: float) -> float:
	return floor(value / 2.0) * 2.0 + 1.0


func tile_edge(value: float) -> float:
	return stepify(value, 2.0)


func compute_snap_position(position: Vector3, snap_mode: int) -> Vector3:
	assert(snap_mode != Snap.MoveMode.AUTO)

	match snap_mode:
		Snap.MoveMode.CENTER:
			return Vector3(
				tile_center(position.x),
				position.y,
				tile_center(position.z)
			)
		Snap.MoveMode.CORNER:
			return Vector3(
				tile_edge(position.x),
				position.y,
				tile_edge(position.z)
			)
		Snap.MoveMode.EDGE_X:
			return Vector3(
				tile_center(position.x),
				position.y,
				tile_edge(position.z)
			)
		Snap.MoveMode.EDGE_Z:
			return Vector3(
				tile_edge(position.x),
				position.y,
				tile_center(position.z)
			)

	assert(snap_mode == Snap.MoveMode.OFF)
	return position


func draw_snap_position(position: Vector3, snap_mode: int) -> void:
	assert(snap_mode != Snap.MoveMode.AUTO)

	var draw_node = get_node("Draw")
	draw_node.set_material_override(draw_material)
	draw_node.clear()
	match snap_mode:
		Snap.MoveMode.OFF:
			draw_node.begin(Mesh.PRIMITIVE_LINES, null)
			draw_node.add_vertex(position)
			draw_node.add_vertex(position + Vector3(0,1,0))
		Snap.MoveMode.CENTER:
			draw_node.begin(Mesh.PRIMITIVE_LINE_LOOP, null)
			draw_node.add_vertex(position + Vector3(-DRAW_WIDTH, DRAW_HEIGHT, -DRAW_WIDTH))
			draw_node.add_vertex(position + Vector3(-DRAW_WIDTH, DRAW_HEIGHT, DRAW_WIDTH))
			draw_node.add_vertex(position + Vector3(DRAW_WIDTH, DRAW_HEIGHT, DRAW_WIDTH))
			draw_node.add_vertex(position + Vector3(DRAW_WIDTH, DRAW_HEIGHT, -DRAW_WIDTH))
		Snap.MoveMode.CORNER:
			draw_node.begin(Mesh.PRIMITIVE_LINES, null)
			draw_node.add_vertex(position + Vector3(-DRAW_WIDTH, DRAW_HEIGHT, 0))
			draw_node.add_vertex(position + Vector3(DRAW_WIDTH, DRAW_HEIGHT, 0))
			draw_node.add_vertex(position + Vector3(0, DRAW_HEIGHT, -DRAW_WIDTH))
			draw_node.add_vertex(position + Vector3(0, DRAW_HEIGHT, DRAW_WIDTH))
		Snap.MoveMode.EDGE_X:
			draw_node.begin(Mesh.PRIMITIVE_LINES, null)
			draw_node.add_vertex(position + Vector3(-DRAW_WIDTH, DRAW_HEIGHT, 0))
			draw_node.add_vertex(position + Vector3(DRAW_WIDTH, DRAW_HEIGHT, 0))
		Snap.MoveMode.EDGE_Z:
			draw_node.begin(Mesh.PRIMITIVE_LINES, null)
			draw_node.add_vertex(position + Vector3(0, DRAW_HEIGHT, -DRAW_WIDTH))
			draw_node.add_vertex(position + Vector3(0, DRAW_HEIGHT, DRAW_WIDTH))
	draw_node.end()


func compute_snap_direction(direction: Vector3) -> Vector3:
	direction = direction.normalized()
	if not Snap.rotate_on:
		return direction

	var dot := Vector3(1, 0, 0).dot(direction)
	var angle := direction.angle_to(Vector3(0, 0, 1)) 
	var snap_angle := stepify(angle, deg2rad(45))  * sign(dot)
#	print("angle: ", rad2deg(angle), ", snap_angle: ", rad2deg(snap_angle))

	var snap_direction := Vector3(0, 0, 1).rotated(Vector3(0, 1, 0), snap_angle)
	return snap_direction


func select_piece(piece: Piece) -> void:
	piece.set_selected()
	selected_piece = piece
	$GameMenu.set_selected(true)


func deselect_piece() -> void:
	selected_piece.set_deselected()
	selected_piece = null
	$GameMenu.set_selected(false)


func get_mouse_floor_intersection(screen_position, height = 0):
	var camera = $camera_origin/camera_pitch/camera
	var start_coordinate = camera.project_ray_origin(screen_position)
	var direction = camera.project_ray_normal(screen_position)
	var x1 = float(start_coordinate.x)
	var y1 = float(start_coordinate.y)
	var z1 = float(start_coordinate.z)
	var x2 = float(direction.x)
	var y2 = float(direction.y)
	var z2 = float(direction.z)
	if (x2 != 0 && y2 != 0 && z2 != 0):
		var x_slope = y2 / x2
		var z_slope = y2 / z2
		var x_at_zero = height - (y1 - x_slope * x1) / x_slope
		var z_at_zero = height - (y1 - z_slope * z1) / z_slope
		return Vector3(x_at_zero, height, z_at_zero)
	else:
		print("Caught a div by zero in tile lookup")

	return null


func get_tile_at_location(position: Vector3, target_floor: int):
	var tile_x := floor(position.x / 2.0)
	var tile_y := floor(position.z / 2.0)
	return sparse_map_lookup(shared_sparse_map, tile_x, tile_y, target_floor)


func get_height_multiplier_at_location(position: Vector3, target_floor: int) -> float:
	var tile = get_tile_at_location(position, target_floor)
	if tile != null:
		if tile.tile_type == "stairsup":
			return 1.0
		if tile.tile_type == "stairsdown":
			return -1.0
	return 0.0


remotesync func ping_NETWORK(position):
	var ping = ping_scene.instance()
	ping.translation.x = position.x
	ping.translation.z = position.z

	ping.rotation.y = rand_range(0,2*PI)

	self.add_child(ping)


func share_room(room_index):
	var tiles = []
	for tile in rooms[room_index]:
		tiles.append([
			tile[0],
			tile[1],
			tile[2],
			sparse_map_lookup(full_sparse_map, tile[0],tile[1],tile[2])
		])

	rpc("share_room_NETWORK", room_index, tiles)


remotesync func share_room_NETWORK(room_index, tiles):
	shared_rooms[room_index] = []

	for tile in tiles:
		if !shared_rooms.has(room_index):
			shared_rooms[room_index] = []
		shared_rooms[room_index].append([tile[0], tile[1], tile[2]])
		sparse_map_insert(shared_sparse_map, tile[0], tile[1], tile[2], tile[3])

	redraw_gridmap_tiles()


remotesync func unhide_tile_NETWORK(x,y,z):
	var tile = sparse_map_lookup(shared_sparse_map,x,y,z)
	tile.hidden = false
	redraw_gridmap_tiles()


func go_upstairs():
	current_floor += 1
	redraw_gridmap_tiles()
	hide_show_floor_objects()
	$GameMenu.set_current_floor(current_floor + 1)


func go_downstairs():
	current_floor -= 1
	redraw_gridmap_tiles()
	hide_show_floor_objects()
	$GameMenu.set_current_floor(current_floor + 1)


# This is slightly wrong right now but that is ok I will fix it later
func redraw_gridmap_tiles():
	$gridmap.clear()
	$unshared_gridmap.clear()

	var visible_tiles = {}
	for mini_id in minis:
		var mini_x = floor(minis[mini_id].object.transform.origin.x/2)
		var mini_y = floor(minis[mini_id].object.transform.origin.z/2)
		var mini_z = floor(minis[mini_id].object.floor_number)
		# print("Mini Coordinates", mini_x, mini_y, mini_z)

		var mini_tile = sparse_map_lookup(shared_sparse_map, mini_x, mini_y, mini_z )
		# print("mini tile", mini_tile)

		if mini_tile != null:
			for room_id in mini_tile.rooms:
				if shared_rooms.has(room_id):
					for tile in shared_rooms[room_id]:
						sparse_map_insert(visible_tiles, tile[0], tile[1], tile[2], sparse_map_lookup(shared_sparse_map, tile[0], tile[1], tile[2]))
	
	if get_tree().is_network_server():
		visible_tiles = shared_sparse_map

	# for z in shared_sparse_map:
	var z = current_floor

	if visible_tiles.has(z):
		for y in visible_tiles[z]:
			for x in visible_tiles[z][y]:

				var tile = sparse_map_lookup(visible_tiles, x, y, z)

				if tile.hidden || tile.tile_type == "wall":
					if should_draw_walls:
						# up,down,left,right
						var up_tile = sparse_map_lookup(visible_tiles, x, y+1, z)
						var down_tile = sparse_map_lookup(visible_tiles, x, y-1, z)
						var left_tile = sparse_map_lookup(visible_tiles, x+1, y, z)
						var right_tile = sparse_map_lookup(visible_tiles, x-1, y, z)

						var key = ""
						if up_tile == null || up_tile.tile_type == "wall" || up_tile.hidden:
							key += "0"
						else:
							key += "1"

						if down_tile == null || down_tile.tile_type == "wall" || down_tile.hidden:
							key += "0"
						else:
							key += "1"
						
						if left_tile == null || left_tile.tile_type == "wall" || left_tile.hidden:
							key += "0"
						else:
							key += "1"

						if right_tile == null || right_tile.tile_type == "wall" || right_tile.hidden:
							key += "0"
						else:
							key += "1"

						var rotation_mapping = {
							# Single Walls (2)
							"1000": [2, 0],
							"0100": [2, 1],
							"0010": [2, 2],
							"0001": [2, 3],
							# Double Walls (3)
							"1010": [3, 2],
							"1001": [3, 0],
							"0110": [3, 1],
							"0101": [3, 3],
							# Tripple Walls (4)
							"1101": [4, 3],
							"1110": [4, 2],
							"1011": [4, 0],
							"0111": [4, 1],
							# Split Walls (5)
							"1100": [5, 0],
							"0011": [5, 2],
							# Full Walls (9)
							"1111": [9, 0]
						}
						$gridmap.set_cell_item (x, 0, y, rotation_mapping[key][0], tile_rotations[rotation_mapping[key][1]])
				else:
					$gridmap.set_cell_item (x, 0, y, tile_types[tile.tile_type], tile_rotations[tile.rotation])

	# for z in full_sparse_map:
	if full_sparse_map.has(z):
		for y in full_sparse_map[z]:
			for x in full_sparse_map[z][y]:
				var unshared_tile = sparse_map_lookup(full_sparse_map, x,y,z)

				if (sparse_map_lookup(shared_sparse_map, x,y,z) == null || unshared_tile.hidden) && unshared_tile.tile_type != "wall":
					$unshared_gridmap.set_cell_item (x, 0, y, tile_types[unshared_tile.tile_type], tile_rotations[unshared_tile.rotation])


func hide_show_floor_objects():
	for mini in minis:
		minis[mini].object.hide_show_on_floor()
	for line in lines:
		lines[line].object.hide_show_on_floor()
	for circle in circles:
		circles[circle].object.hide_show_on_floor()
	for rectangle in rectangles:
		rectangles[rectangle].object.hide_show_on_floor()


func sparse_map_lookup(sparsemap, x, y, z):
	x = int(x)
	y = int(y)
	z = int(z)

	if !sparsemap.has(z):
		return null

	if !(sparsemap[z].has(y)):
		return null

	if !sparsemap[z][y].has(x):
		return null

	return sparsemap[z][y][x]


func sparse_map_insert(sparsemap, x, y, z, value):
	x = int(x)
	y = int(y)
	z = int(z)
	if !sparsemap.has(z):
		sparsemap[z] = {}

	if !sparsemap[z].has(y):
		sparsemap[z][y] = {}

	sparsemap[z][y][x] = value


func new_sparse_tile(tile_type):
	return {
		"tile_type": tile_type,
		"rooms": [],
		"rotation": 0,
		"hidden": false
	}


remotesync func reset_map_NETWORK():
	full_sparse_map = {}
	shared_sparse_map = {}
	rooms = []
	shared_rooms = {}


func load_room_from_file(filename):
	rpc("reset_map_NETWORK")

	var raw_tiles = load_file(filename)

	# Array of xyz coordinates of things that have not yet been assigned to a room
	var possible_rooms = []
	var starts = []
	var start_floor = -1

	for z in range(len(raw_tiles)):
		var start = [-1, -1]
		# Find Start Bit
		for y in range(len(raw_tiles[z])):
			for x in range(len(raw_tiles[z][y])):
				if raw_tiles[z][y][x] == "S" || raw_tiles[z][y][x] == "A" || raw_tiles[z][y][x] == "B":
					if start != [-1,-1]:
						print("ERROR Found Multiple anchor locations on one floor")
					start = [x, y]

					if raw_tiles[z][y][x] == "S":
						if start_floor != -1:
							print("ERROR Found Multiple start floors")
						start_floor = z

		if start == [-1,-1]:
			print("ERROR CANNOT FIND START BIT")

		starts.append(start)

	if start_floor == -1:
		print("ERROR CANNOT FIND START FLOOR")

	# Populate Sparse List of Rooms
	for tz in range(len(raw_tiles)):
		for ty in range(len(raw_tiles[tz])):
			for tx in range(len(raw_tiles[tz][ty])):
				var x = int(tx-starts[tz][0])
				var y = int(ty-starts[tz][1])
				var z = int(tz-start_floor)

				# Regular Tile
				if raw_tiles[tz][ty][tx] == "X" || raw_tiles[tz][ty][tx] == "B":

					sparse_map_insert(full_sparse_map, x, y, z, new_sparse_tile("floor"))
					possible_rooms.append([x,y,z])

				elif raw_tiles[tz][ty][tx] == "S":
					sparse_map_insert(full_sparse_map, x, y, z, new_sparse_tile("start"))
					possible_rooms.append([x,y,z])

				# Doors
				elif raw_tiles[tz][ty][tx] == "D":
					sparse_map_insert(full_sparse_map, x, y, z, new_sparse_tile("door"))

				# Hidden Doors
				elif raw_tiles[tz][ty][tx] == "H":
					var hidden_door_tile = new_sparse_tile("hiddendoor")

					# Set a flag to not display this tile until it is no longer hidden
					hidden_door_tile.hidden = true

					sparse_map_insert(full_sparse_map, x, y, z, hidden_door_tile)

				# Staircases
				elif raw_tiles[tz][ty][tx] == "U":
					sparse_map_insert(full_sparse_map, x, y, z, new_sparse_tile("stairsup"))

				elif raw_tiles[tz][ty][tx] == "L":
					sparse_map_insert(full_sparse_map, x, y, z, new_sparse_tile("stairsdown"))

				# Other
				elif ignored_characters.has(raw_tiles[tz][ty][tx]):
					pass
				else:
					print("Found an unknown character at ", tx, ",", ty,",",tz,"[",raw_tiles[tz][ty][tx],"]")

	# Populate Rotations
	for z in full_sparse_map:
		for y in full_sparse_map[z]:
			for x in full_sparse_map[z][y]:
				if full_sparse_map[z][y][x].tile_type == "door" || full_sparse_map[z][y][x].tile_type == "hiddendoor":
					var up_tile = sparse_map_lookup(full_sparse_map, x, y+1, z)
					var down_tile = sparse_map_lookup(full_sparse_map, x, y-1, z)
					var left_tile = sparse_map_lookup(full_sparse_map, x+1, y, z)
					var right_tile = sparse_map_lookup(full_sparse_map, x-1, y, z)

					if up_tile != null && up_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 3

					if down_tile != null && down_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 2

					if left_tile != null && left_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 0

					if right_tile != null && right_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 1

				if full_sparse_map[z][y][x].tile_type == "stairsup" || full_sparse_map[z][y][x].tile_type == "stairsdown":
					var up_tile = sparse_map_lookup(full_sparse_map, x, y+1, z)
					var down_tile = sparse_map_lookup(full_sparse_map, x, y-1, z)
					var left_tile = sparse_map_lookup(full_sparse_map, x+1, y, z)
					var right_tile = sparse_map_lookup(full_sparse_map, x-1, y, z)

					if up_tile != null && up_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 3

					if down_tile != null && down_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 2

					if left_tile != null && left_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 0

					if right_tile != null && right_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 1

				if full_sparse_map[z][y][x].tile_type == "start":
					var up_tile = sparse_map_lookup(full_sparse_map, x, y+1, z)
					var down_tile = sparse_map_lookup(full_sparse_map, x, y-1, z)
					var left_tile = sparse_map_lookup(full_sparse_map, x+1, y, z)
					var right_tile = sparse_map_lookup(full_sparse_map, x-1, y, z)

					if up_tile != null && up_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 2

					if down_tile != null && down_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 3

					if left_tile != null && left_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 1

					if right_tile != null && right_tile.tile_type == "floor":
						full_sparse_map[z][y][x].rotation = 0

	# Assemble all of the tiles into rooms
	while len(possible_rooms) > 0:
		var built_room = build_room(
			possible_rooms[0][0],
			possible_rooms[0][1],
			possible_rooms[0][2],
			full_sparse_map,
			[]
		)

		for tile_coordinate in built_room:
			possible_rooms.erase(tile_coordinate)

			var tile = sparse_map_lookup(full_sparse_map, tile_coordinate[0], tile_coordinate[1], tile_coordinate[2])
			tile.rooms.append(len(rooms))

		rooms.append(built_room)

	# Populate Walls
	var wall_sparsemap = {}
	for z in full_sparse_map:
		for y in full_sparse_map[z]:
			for x in full_sparse_map[z][y]:
				var tile = full_sparse_map[z][y][x]
				var up_tile = sparse_map_lookup(full_sparse_map, x, y+1, z)
				var down_tile = sparse_map_lookup(full_sparse_map, x, y-1, z)
				var left_tile = sparse_map_lookup(full_sparse_map, x+1, y, z)
				var right_tile = sparse_map_lookup(full_sparse_map, x-1, y, z)

				if tile.tile_type == "floor" || tile.tile_type == "door" || tile.tile_type == "stairsdown" || tile.tile_type == "stairsup":
					if up_tile == null:
						sparse_map_insert(wall_sparsemap, x, y+1, z, new_sparse_tile("wall"))
						for room in tile.rooms:
							rooms[room].append([x,y+1,z])
					if down_tile == null:
						sparse_map_insert(wall_sparsemap, x, y-1, z, new_sparse_tile("wall"))
						for room in tile.rooms:
							rooms[room].append([x,y-1,z])
					if left_tile == null:
						sparse_map_insert(wall_sparsemap, x+1, y, z, new_sparse_tile("wall"))
						for room in tile.rooms:
							rooms[room].append([x+1,y,z])
					if right_tile == null:
						sparse_map_insert(wall_sparsemap, x-1, y, z, new_sparse_tile("wall"))
						for room in tile.rooms:
							rooms[room].append([x-1,y,z])

	for z in wall_sparsemap:
		for y in wall_sparsemap[z]:
			for x in wall_sparsemap[z][y]:
				sparse_map_insert(full_sparse_map, x, y, z, wall_sparsemap[z][y][x])
	
	# Reveal the first room
	# print(rooms[sparse_map_lookup(full_sparse_map,0,0,0).rooms[0]])
	share_room(sparse_map_lookup(full_sparse_map,0,0,0).rooms[0])


func build_room(start_x: int, start_y:int , start_z:int, sparsemap, room):
	var tiles_to_check = [
		[start_x, start_y, start_z]
	]

	while(len(tiles_to_check) > 0):
		var tile_coordinate = tiles_to_check.pop_front()
		var x = int(tile_coordinate[0])
		var y = int(tile_coordinate[1])
		var z = int(tile_coordinate[2])

		# If there is no tile in this spot then ignore this tile
		var tile = sparse_map_lookup(sparsemap, x,y,z)
		if tile == null:
			continue

		# If we have already added this tile to the room then ignore this tile
		if room.has([x,y,z]):
			continue

		# If the tile is a floor tile, which could extend the room to other
		# tiles, add this tile to the room and add the possible adjacent tiles
		# to the list of tiles to check for in future loops.
		if tile.tile_type == "floor" || tile.tile_type == "start":
			room.append([x,y,z])

			tiles_to_check.append([x+1, y, z])
			tiles_to_check.append([x-1, y, z])
			tiles_to_check.append([x, y+1, z])
			tiles_to_check.append([x, y-1, z])

		# If the tile is a blocker-type tile that would prevent the room from
		# expanding, then add the tile to the room and do not add further
		# adjacent tiles to it.
		# NOTE: Stairs are excluded here due to technically being two tiles
		#       one on each floor, and thus needing a bit more logic
		elif tile.tile_type == "door" || tile.tile_type == "hiddendoor":
			room.append([x,y,z])

		# If the tile is a stair, treat it as a blocker-type tile, but add both
		# the stair and its pair to the room.
		elif tile.tile_type == "stairsup":
			if sparse_map_lookup(sparsemap, x, y, z+1).tile_type != "stairsdown":
				print("ERROR: NON MATCHING STAIRS")
			room.append([x,y,z])
			room.append([x,y,z+1])

		elif tile.tile_type == "stairsdown":
			if sparse_map_lookup(sparsemap, x, y, z-1).tile_type != "stairsup":
				print("ERROR: NON MATCHING STAIRS")
			room.append([x,y,z])
			room.append([x,y,z-1])

		# If we have not caught the tile type then it is an unknown type and
		# we should yell at someone.
		else:
			print("UNKNOWN TYPE", tile.tile_type)

	return room

func load_file(filename):
	var floors = []
	var floor_layout = []
	var f = File.new()
	f.open(filename, File.READ)
	var index = 1
	while not f.eof_reached():
		var line = f.get_line()

		# Split the file into floors
		if len(line) > 0 && line[0] == "-":
			floors.append(floor_layout)
			floor_layout = []
			continue

		# Remove all the whitespaces between each character
		var compressed_line = ""
		var grab = true
		for i in range(len(line)):

			if grab:
				compressed_line += line[i]
			elif grab && line[i] != " ":
				print("ERROR FOUND NON_WHITESPACE")
			grab = !grab

		floor_layout.append(compressed_line)
		index += 1
	floors.append(floor_layout)
	f.close()
	return floors


func resend_shared_map():
	for room_id in shared_rooms:
		share_room(room_id)

	# More stuff for objects needs to be added here
	# share_room(sparse_map_lookup(full_sparse_map,0,0,0).rooms[0])
	# rpc("load_room", shared_rooms)
	# rpc("load_objects", shared_objects)


remotesync func load_room(room_objects):
	# print("loading_room")
	for grid_object in room_objects:
		$gridmap.set_cell_item (grid_object[0], grid_object[1], grid_object[2], grid_object[3], tile_rotations[grid_object[4]])


func resend_objects():
	for mini_id in minis:
		var mini = minis[mini_id]
		rpc("create_mini_NETWORK",
			mini_id,
			mini.color,
			mini.style,
			mini.name,
			mini.object.floor_number,
			mini.object.translation
		)

	for line_id in lines:
		var line = lines[line_id]
		rpc("create_line_NETWORK",
			line_id,
			line.color,
			line.length,
			line.width,
			line.name,
			line.floor_number,
			line.object.translation
		)

	for circle_id in circles:
		var circle = circles[circle_id]
		rpc("create_circle_NETWORK",
			circle_id,
			circle.color,
			circle.radius,
			circle.arc,
			circle.name,
			circle.floor_number,
			circle.object.translation
		)

	for rectangle_id in rectangles:
		var rectangle = rectangles[rectangle_id]
		rpc("create_rectangle_NETWORK",
			rectangle_id,
			rectangle.color,
			rectangle.x,
			rectangle.z,
			rectangle.name,
			rectangle.floor_number,
			rectangle.object.translation
		)


remotesync func create_mini_NETWORK(id: String, color: Color, style: int, name: String, floor_number: int, position: Vector3) -> void:
	if minis.has(id):
		print("WARNING: mini id already exists!")
		return

	var mini = mini_scene.instance()
	mini.name = id

	 # This will matter for larger units
	mini.tile_size_x = models[style][1]
	mini.tile_size_z = models[style][1]
	
	mini.get_node("mesh").rotation_degrees.y = models[style][2]
	mini.get_node("name").translation.y = models[style][3]
	mini.get_node("mesh").mesh = load("res://mini_meshes/" + models[style][4])

	var label = mini.get_node("name/viewport/name/center/label")
	label.text = name

	var mini_material = load("res://mini_material.tres").duplicate()
	var mini_material_glow = load("res://mini_material_glow.tres").duplicate()
	mini_material.set_shader_param("albedo", color)
	mini_material.next_pass = mini_material_glow

	mini.get_node("mesh").set_surface_material(0, mini_material)

	self.add_child(mini)

	mini.translation.x = position.x
	mini.translation.z = position.z

	mini.floor_number = floor_number
	mini.hide_show_on_floor()

	minis[id] = {
		"color": color,
		"style": style,
		"name": name,
		"object": mini
	}

	redraw_gridmap_tiles()


remotesync func create_line_NETWORK(id: String, color: Color, length: int, width: int, name: String, floor_number: int, position: Vector3) -> void:
	if lines.has(id):
		print("WARNING: line id already exists!")
		return

	var rectangle = rectangle_aoe_scene.instance()
	rectangle.name = id
	rectangle.tile_size_x = 1
	rectangle.tile_size_z = 1

	# Note: The tile dimensions are 2 by 2. The length is in units of 1/2 the
	# tile_size. The rectangle_aoe_scene is normally drawn from the center. The
	# offset to the edge is half the rectangle, or "all" of length, plus 1 to
	# move it away from the center of the tile.
	var z_offset = length + 1
	var rectangle_sprite = rectangle.get_node("sprite")
	rectangle_sprite.translation.z = z_offset

	# Set the shader border color
	var rectangle_material = rectangle.get_node("sprite/viewport/texture/sprite").material
	rectangle_material.set_shader_param("color", color)
	rectangle_material.set_shader_param("image_size", length * 200)

	# Set the text colors and names
	var label1 = rectangle.get_node("sprite/viewport/texture/sprite/label1")
	label1.set("custom_colors/font_color", color)
	label1.text = name

	var label2 = rectangle.get_node("sprite/viewport/texture/sprite/label2")
	label2.set("custom_colors/font_color", color)
	label2.text = name

	var label3 = rectangle.get_node("sprite/viewport/texture/sprite/label3")
	label3.set("custom_colors/font_color", color)
	label3.text = name

	var label4 = rectangle.get_node("sprite/viewport/texture/sprite/label4")
	label4.set("custom_colors/font_color", color)
	label4.text = name

	# Set the size
	var viewport = rectangle.get_node("sprite/viewport")
	viewport.size.x = width * 200
	viewport.size.y = length * 200

	# The BoxShape extents are considered "half" extents,
	# https://docs.godotengine.org/en/stable/classes/class_boxshape.html#class-boxshape
	var collision_shape = rectangle.get_node("collision_shape")
	collision_shape.shape.extents.x = width
	collision_shape.shape.extents.z = length
	collision_shape.translation.z = z_offset

	self.add_child(rectangle)

	rectangle.translation.x = position.x
	rectangle.translation.z = position.z

	rectangle.floor_number = floor_number
	rectangle.hide_show_on_floor()

	lines[id] = {
		"color": color,
		"length": length,
		"width": width,
		"name": name,
		"floor_number": floor_number,
		"object": rectangle
	}


remotesync func create_circle_NETWORK(id: String, color: Color, radius: int, arc: float, name: String, floor_number: int, position: Vector3) -> void:
	if circles.has(id):
		print("WARNING: circle id already exists!")
		return

	var circle = circle_aoe_scene.instance()
	circle.name = id
	circle.tile_size_x = radius
	circle.tile_size_z = radius

	# Set the shader border color
	var circle_material = circle.get_node("sprite/viewport/texture/sprite").material
	circle_material.set_shader_param("color", color)
	circle_material.set_shader_param("image_size", radius * 200)
	circle_material.set_shader_param("arc", arc)

	# Set the text colors and names
	var label1 = circle.get_node("sprite/viewport/texture/sprite/center/labels/label1")
	label1.set("custom_colors/font_color", color)
	label1.text = name

	var label2 = circle.get_node("sprite/viewport/texture/sprite/center/labels/label2")
	label2.set("custom_colors/font_color", color)
	label2.text = name

	# Set the radius
	var viewport = circle.get_node("sprite/viewport")
	viewport.size.x = radius * 200
	viewport.size.y = radius * 200
	var collision_shape = circle.get_node("collision_shape")
	collision_shape.shape.radius = radius

	self.add_child(circle)

	circle.translation.x = position.x
	circle.translation.z = position.z

	circle.floor_number = floor_number
	circle.hide_show_on_floor()

	circles[id] = {
		"color": color,
		"radius": radius,
		"arc": arc,
		"name": name,
		"floor_number": floor_number,
		"object": circle
	}


remotesync func create_rectangle_NETWORK(id: String, color: Color, x: int, z: int, name: String, floor_number: int, position: Vector3) -> void:
	if rectangles.has(id):
		print("WARNING: rectangle id already exists!")
		return

	var rectangle = rectangle_aoe_scene.instance()
	rectangle.name = id
	rectangle.tile_size_x = x
	rectangle.tile_size_z = z

	# Set the shader border color
	var rectangle_material = rectangle.get_node("sprite/viewport/texture/sprite").material
	rectangle_material.set_shader_param("color", color)
	rectangle_material.set_shader_param("image_size", x * 200)

	# Set the text colors and names
	var label1 = rectangle.get_node("sprite/viewport/texture/sprite/label1")
	label1.set("custom_colors/font_color", color)
	label1.text = name

	var label2 = rectangle.get_node("sprite/viewport/texture/sprite/label2")
	label2.set("custom_colors/font_color", color)
	label2.text = name

	var label3 = rectangle.get_node("sprite/viewport/texture/sprite/label3")
	label3.set("custom_colors/font_color", color)
	label3.text = name

	var label4 = rectangle.get_node("sprite/viewport/texture/sprite/label4")
	label4.set("custom_colors/font_color", color)
	label4.text = name

	# Set the size
	var viewport = rectangle.get_node("sprite/viewport")
	viewport.size.x = x * 200
	viewport.size.y = z * 200

	# The BoxShape extents are considered "half" extents,
	# https://docs.godotengine.org/en/stable/classes/class_boxshape.html#class-boxshape
	var collision_shape = rectangle.get_node("collision_shape")
	collision_shape.shape.extents.x = x
	collision_shape.shape.extents.z = z

	self.add_child(rectangle)

	rectangle.translation.x = position.x
	rectangle.translation.z = position.z

	rectangle.floor_number = floor_number
	rectangle.hide_show_on_floor()

	rectangles[id] = {
		"color": color,
		"x": x,
		"z": z,
		"name": name,
		"floor_number": floor_number,
		"object": rectangle
	}


func _on_Network_player_connected():
	print("player_connected")
	if get_tree().is_network_server():
		resend_shared_map()
		resend_objects()


func _on_MainMenu_start_game():
	$MainMenu.hide()
	if get_tree().is_network_server():
		$GameMenu.show_dm_controls()
	$GameMenu.show()


func _on_GameMenu_map_changed(filename):
	print("_on_MapControls_map_changed: " + filename)
	load_room_from_file(filename)


func _on_GameMenu_share_room():
		# Try to get what tile the camera center is currently on
	# Share all the rooms that tile belongs to
	var x = int(floor($camera_origin.translation.x/2))
	var y = int(floor($camera_origin.translation.z/2))
	var z = current_floor

	var tile = sparse_map_lookup(full_sparse_map,x,y,z)

	if tile == null:
		# print("No Tile to Share")
		return

	var rooms = tile.rooms;
	for room in rooms:
		share_room(room)


func _on_GameMenu_unhide_tile():
	var x = int(floor($camera_origin.translation.x/2))
	var y = int(floor($camera_origin.translation.z/2))
	var z = current_floor

	rpc("unhide_tile_NETWORK", x, y, z)
	$GameMenu.set_unhide_tile_disabled(true)


func _on_GameMenu_create_mini(name: String, color: Color, model_index: int) -> void:
	var id: String = str(get_tree().get_network_unique_id()) + "_" + str(randi())

	var snapped_position: Vector3 = compute_snap_position($camera_origin.translation, Snap.MoveMode.CENTER)
	snapped_position.y = 0

	if !get_tree().is_network_server():
		snapped_position = Vector3(1, 0, 1)

	rpc("create_mini_NETWORK",
		id,
		color,
		model_index,
		name,
		current_floor,
		snapped_position
	)


func _on_GameMenu_create_line(name, color, length, width):
	var id: String = str(get_tree().get_network_unique_id()) + "_" + str(randi())

	var tile_size_x: int = length / 5
	var tile_size_z: int = width / 5

	# For line spell shapes, always snap to the center of the tile
	var snapped_position: Vector3 = compute_snap_position($camera_origin.translation, Snap.MoveMode.CENTER)
	snapped_position.y = 0

	rpc("create_line_NETWORK",
		id,
		color,
		tile_size_x,
		tile_size_z,
		name,
		current_floor,
		snapped_position
	)


func _on_GameMenu_create_circle(name: String, color: Color, radius: int, arc_degrees: float) -> void:
	var id: String = str(get_tree().get_network_unique_id()) + "_" + str(randi())

	var tile_size: int = (radius * 2) / 5
	
	var local_snap_mode: int = get_auto_snap_mode(tile_size, tile_size)
	var snapped_position: Vector3 = compute_snap_position($camera_origin.translation, local_snap_mode)
	snapped_position.y = 0

	rpc("create_circle_NETWORK",
		id,
		color,
		tile_size,
		arc_degrees / 180 * PI,
		name,
		current_floor,
		snapped_position
	)


func _on_GameMenu_create_rectangle(name: String, color: Color, x: int, z: int):
	var id: String = str(get_tree().get_network_unique_id()) + "_" + str(randi())

	var tile_size_x: int = x / 5
	var tile_size_z: int = z / 5

	var local_snap_mode: int = get_auto_snap_mode(tile_size_x, tile_size_z)
	var snapped_position: Vector3 = compute_snap_position($camera_origin.translation, local_snap_mode)
	snapped_position.y = 0

	rpc("create_rectangle_NETWORK",
		id,
		color,
		tile_size_x,
		tile_size_z,
		name,
		current_floor,
		snapped_position
	)


func _on_GameMenu_delete():
	var to_delete = selected_piece
	change_left_click_action(LeftClickAction.SELECT)
	to_delete.delete()
	redraw_gridmap_tiles()
	assert(selected_piece == null)


func _on_GameMenu_toggle_ping(is_enabled):
	if is_enabled:
		change_left_click_action(LeftClickAction.PING)
	else:
		change_left_click_action(LeftClickAction.SELECT)


func _on_GameMenu_toggle_walls(show_walls):
	should_draw_walls = show_walls
	redraw_gridmap_tiles()


func _on_GameMenu_up_level():
	go_upstairs()


func _on_GameMenu_down_level():
	go_downstairs()


func _on_GameMenu_popup_toggled(is_showing):
	is_popup_showing = is_showing
