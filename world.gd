class_name World
extends Node3D


@export_node_path("Camera3D") var camera_path: NodePath
@export_node_path("DirectionalLight3D") var light_path: NodePath


var camera: Camera3D:
    get:
        return _camera

var light: DirectionalLight3D:
    get:
        return _light


var sdf_objects: Array[SdfObjectData]:
    get:
        return _sdf_objects


@onready var _camera := get_node(camera_path) as Camera3D
@onready var _light := get_node(light_path) as DirectionalLight3D
@onready var _sdf_objects := _create_sdf_objects_data()


static func _create_sdf_data_for_box(box: CSGBox3D) -> SdfBox:
    var result := SdfBox.new()
    result.transform = box.global_transform
    var material := box.material
    if is_instance_of(material, StandardMaterial3D):
        result.color = (material as StandardMaterial3D).albedo_color
    else:
        result.color = Color.WHITE
    result.size = box.size
    return result


static func _create_sdf_data_for(node: Node3D) -> Array[SdfObjectData]:
    var result: Array[SdfObjectData] = []
    for child in node.get_children():
        if not is_instance_of(child, Node3D) or not (child as Node3D).visible:
            continue

        if is_instance_of(child, CSGBox3D):
            result.push_back(_create_sdf_data_for_box(child as CSGBox3D))

        result.append_array(_create_sdf_data_for(child))
    return result


func _create_sdf_objects_data() -> Array[SdfObjectData]:
    return _create_sdf_data_for(self)


class SdfObjectData extends Resource:
    var transform: Transform3D
    var color: Color


class SdfBox extends SdfObjectData:
    var size: Vector3
