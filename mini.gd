class_name Mini
extends Piece


func set_selected() -> void:
	var surface_material = self.get_node("mesh").get_surface_material(0)
	surface_material.set_shader_param("enable", true)
	surface_material.next_pass.set_shader_param("enable", true)
	_is_selected = true


func set_deselected() -> void:
	var surface_material = self.get_node("mesh").get_surface_material(0)
	surface_material.set_shader_param("enable", false)
	surface_material.next_pass.set_shader_param("enable", false)
	_is_selected = false


func set_location_local(position: Vector3, target_floor: int) -> void:
	var main = get_node("/root/Main")
	var height_multiplier: float = main.get_height_multiplier_at_location(position, target_floor)
	position.y = height_multiplier * 1.0
	self.global_transform.origin = position
	self.floor_number = target_floor + height_multiplier * 0.4


func end_move_floor_change() -> void:
	var main = get_node("/root/Main")
	var current_floor: int = round(self.floor_number)
	var height_multiplier: float = main.get_height_multiplier_at_location(self.global_transform.origin, current_floor)
	self.floor_number = self.floor_number + height_multiplier * 0.4

	# Redraw rooms so that we can see new fog of war areas
	main.redraw_gridmap_tiles()
