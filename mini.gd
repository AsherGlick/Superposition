extends Piece


func set_selected() -> void:
	var surface_material = self.get_node("mesh").get_surface_material(0)
	surface_material.set_shader_param("enable", true)
	surface_material.next_pass.set_shader_param("enable", true)


func set_deselected() -> void:
	var surface_material = self.get_node("mesh").get_surface_material(0)
	surface_material.set_shader_param("enable", false)
	surface_material.next_pass.set_shader_param("enable", false)


func end_move_floor_change() -> void:
	var main = get_tree().get_root().get_node("Main")

	var x := floor(self.transform.origin.x/2)
	var y := floor(self.transform.origin.z/2)
	
	print(Vector2(x,y))
	var tile = main.sparse_map_lookup(
		main.shared_sparse_map,
		x,
		y,
		floor(self.floor_number)
	)

	if tile != null:
		if tile.tile_type == "stairsup":
			self.floor_number = self.floor_number + .5
		if tile.tile_type == "stairsdown":
			self.floor_number = self.floor_number - .5

	# Redraw rooms so that we can see new fog of war areas
	main.redraw_gridmap_tiles()
