extends CenterContainer


func _ready():
	if not (OS.has_feature("dungeon_master") or OS.has_feature("editor")):
		$VBoxContainer/VBoxContainer/Host.visible = false

	$VBoxContainer/Version.text = "Version: " + Version.id()


func _on_HostGame_pressed():
	Network.create_server()
	get_tree().change_scene("res://root.tscn")


func _on_JoinGame_pressed():
	Network.connect_to_server($VBoxContainer/VBoxContainer/IpAddress.text)
	get_tree().change_scene("res://root.tscn")
