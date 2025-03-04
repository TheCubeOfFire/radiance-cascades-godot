extends Node


@export var image_size := Vector2i(512, 512)
@export var workgroup_size := Vector2i(16, 16)
@export var uniform_image_binding := 0
@export var uniform_image_set := 0


var _render_method_index := 0
var _output_texture: Texture2DRD = null

#var _time := 0.0

var _test_pipeline := RID()
var _test_uniform_set := RID()
var _sdf_visualization_pipeline := RID()
var _sdf_output_uniform_set := RID()
var _sdf_input_uniform_set := RID()
var _sdf_input_uniform_buffer := RID()
var _sdf_input_object_buffer := RID()
var _output_texture_gpu := RID()


@onready var _main_display := $MainDisplay as MainDisplay
@onready var _world := $SubViewport/World as World
@onready var _rendering_device := RenderingServer.get_rendering_device()


func _ready() -> void:
    _output_texture = _main_display.radiance_cascades_texture_rect.texture

    var camera := _world.camera
    # view matrix is usually the matrix transforming world coordinates to view coordinates
    # camera transform is the tranformation from local camera coordinates to world coordinates
    # so view matrix is simply the inverse of the camera transform
    var inv_view_matrix := Projection(camera.get_camera_transform())
    var projection_matrix := camera.get_camera_projection()
    var inv_projection_matrix := projection_matrix.inverse()

    var camera_position := Vector4(
        camera.global_position.x,
        camera.global_position.y,
        camera.global_position.z,
        1.0
    )

    var ndc := Vector4(0.0, -1.0, -1.0, 1.0)
    ndc.y = -ndc.y

    var view_coord := inv_projection_matrix * ndc
    view_coord /= view_coord.w

    var world_coord := inv_view_matrix * view_coord

    var ray_dir = camera_position.direction_to(world_coord)

    var object_data := PackedFloat32Array()
    for object in _world.sdf_objects:
        var model_transform := object.transform
        var inv_model := Projection(model_transform.affine_inverse())
        var local_coords := inv_model * world_coord

        # mat4 encoding
        for column in 4:
            for row in 4:
                object_data.append(inv_model[column][row])

        # vec3 encoding
        if is_instance_of(object, World.SdfBox):
            var sdf_box := object as World.SdfBox
            var box_size := 0.5 * sdf_box.size
            object_data.append(box_size.x)
            object_data.append(box_size.y)
            object_data.append(box_size.z)

            # 1 float of padding
            object_data.append(0.0)
        else:
            for i in 4:
                object_data.append(0.0)

    var object_data_bytes := object_data.to_byte_array()

    RenderingServer.call_on_render_thread(_render_thread_init.bind(image_size, uniform_image_binding, uniform_image_set, inv_view_matrix, inv_projection_matrix, object_data_bytes))


func _process(_delta: float) -> void:
    if _is_custom_rendering_enabled():
        #_time += delta
        #var period := 20.0
        #var depth := 2.0 * fmod(_time, period) / period - 1.0
        RenderingServer.call_on_render_thread(_render_thread_render.bind(image_size, _render_method_index, workgroup_size, uniform_image_set))


func _notification(what: int) -> void:
    if what == NOTIFICATION_PREDELETE:
        _cleanup()
        RenderingServer.call_on_render_thread(_cleanup_gpu)


func _unhandled_key_input(event: InputEvent) -> void:
    if is_instance_of(event, InputEventKey):
        var key_event := event as InputEventKey
        if key_event.is_released():
            match key_event.physical_keycode:
                KEY_1:
                    _change_render_method(0)
                KEY_2:
                    _change_render_method(1)
                KEY_3:
                    _change_render_method(2)

            get_viewport().set_input_as_handled()


func _is_custom_rendering_enabled() -> bool:
    return _render_method_index != 0


func _cleanup() -> void:
    if _output_texture != null:
        _output_texture.texture_rd_rid = RID()


func _change_render_method(index: int) -> void:
    if index < 0 or index >= 3:
        return

    if index == _render_method_index:
        return

    _render_method_index = index
    _main_display.enable_radiance_cascades(_is_custom_rendering_enabled())


func _cleanup_gpu() -> void:
    _rendering_device.free_rid(_sdf_input_object_buffer)
    _rendering_device.free_rid(_sdf_input_uniform_buffer)

    _rendering_device.free_rid(_test_uniform_set)
    _rendering_device.free_rid(_sdf_output_uniform_set)

    _rendering_device.free_rid(_output_texture_gpu)

    _rendering_device.free_rid(_test_pipeline)
    _rendering_device.free_rid(_sdf_visualization_pipeline)


func _render_thread_init(local_image_size: Vector2i, local_image_binding: int, local_image_set: int, inv_view_matrix: Projection, inv_projection_matrix: Projection, object_data_bytes: PackedByteArray) -> void:
    var camera_position := inv_view_matrix.w

    var output_format := RDTextureFormat.new()
    output_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
    output_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
    output_format.width = local_image_size.x
    output_format.height = local_image_size.y
    output_format.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT \
        | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT \
        | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
        | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT

    var output_texture_view := RDTextureView.new()

    _output_texture_gpu = _rendering_device.texture_create(output_format, output_texture_view)

    # Set texture RID on game thread
    var update_texture_rid = func (texture_rid: RID) -> void:
        _output_texture.texture_rd_rid = texture_rid

    update_texture_rid.bind(_output_texture_gpu).call_deferred()

    var test_shader_file: RDShaderFile = load("res://test.glsl")
    var test_shader_spirv := test_shader_file.get_spirv()
    var test_shader := _rendering_device.shader_create_from_spirv(test_shader_spirv)

    _test_pipeline = _rendering_device.compute_pipeline_create(test_shader)

    var sdf_shader_file: RDShaderFile = load("res://sdf_rendering.glsl")
    var sdf_shader_spirv := sdf_shader_file.get_spirv()
    var sdf_shader := _rendering_device.shader_create_from_spirv(sdf_shader_spirv)

    _sdf_visualization_pipeline = _rendering_device.compute_pipeline_create(sdf_shader)

    var output_image_uniform := RDUniform.new()
    output_image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
    output_image_uniform.binding = local_image_binding
    output_image_uniform.add_id(_output_texture_gpu)

    _test_uniform_set = _rendering_device.uniform_set_create(
        [output_image_uniform],
        test_shader,
        local_image_set
    )

    _sdf_output_uniform_set = _rendering_device.uniform_set_create(
        [output_image_uniform],
        sdf_shader,
        local_image_set
    )

    var sdf_uniform_data := PackedVector4Array()

    sdf_uniform_data.append(inv_view_matrix[0])
    sdf_uniform_data.append(inv_view_matrix[1])
    sdf_uniform_data.append(inv_view_matrix[2])
    sdf_uniform_data.append(inv_view_matrix[3])

    sdf_uniform_data.append(inv_projection_matrix[0])
    sdf_uniform_data.append(inv_projection_matrix[1])
    sdf_uniform_data.append(inv_projection_matrix[2])
    sdf_uniform_data.append(inv_projection_matrix[3])

    sdf_uniform_data.append(camera_position)

    var sdf_uniform_bytes := sdf_uniform_data.to_byte_array()

    _sdf_input_uniform_buffer = _rendering_device.uniform_buffer_create(sdf_uniform_bytes.size(), sdf_uniform_bytes)

    var sdf_input_uniform := RDUniform.new()
    sdf_input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
    # TODO do not hardcode binding
    sdf_input_uniform.binding = 0
    sdf_input_uniform.add_id(_sdf_input_uniform_buffer)

    _sdf_input_object_buffer = _rendering_device.storage_buffer_create(object_data_bytes.size(), object_data_bytes)

    var sdf_object_buffer := RDUniform.new()
    sdf_object_buffer.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
    sdf_object_buffer.binding = 1
    sdf_object_buffer.add_id(_sdf_input_object_buffer)

    # TODO do not hardcode uniform set
    _sdf_input_uniform_set = _rendering_device.uniform_set_create(
        [sdf_input_uniform, sdf_object_buffer],
        sdf_shader,
        1
    )


func _render_thread_render(local_image_size: Vector2i, local_pipeline_index: int, local_workgroup_size: Vector2i, local_image_set: int) -> void:
    var workgroup_count := local_image_size / local_workgroup_size

    var compute_list := _rendering_device.compute_list_begin()
    if local_pipeline_index == 2:
        _rendering_device.compute_list_bind_compute_pipeline(compute_list, _sdf_visualization_pipeline)
        _rendering_device.compute_list_bind_uniform_set(compute_list, _sdf_output_uniform_set, local_image_set)
        # TODO do not hardcode set
        _rendering_device.compute_list_bind_uniform_set(compute_list, _sdf_input_uniform_set, 1)

        #var push_constants := PackedFloat32Array()
        #push_constants.append(depth)
        #var push_constants_bytes := push_constants.to_byte_array()
        #var alignment := 4 * 4 # 4 floats
        #@warning_ignore("integer_division")
        #var padded_size := (push_constants_bytes.size() + alignment - 1) / alignment * alignment
        #push_constants_bytes.resize(padded_size)
        #_rendering_device.compute_list_set_push_constant(compute_list, push_constants_bytes, push_constants_bytes.size())
    else:
        _rendering_device.compute_list_bind_compute_pipeline(compute_list, _test_pipeline)
        _rendering_device.compute_list_bind_uniform_set(compute_list, _test_uniform_set, local_image_set)
    _rendering_device.compute_list_dispatch(compute_list, workgroup_count.x, workgroup_count.y, 1)
    _rendering_device.compute_list_end()
