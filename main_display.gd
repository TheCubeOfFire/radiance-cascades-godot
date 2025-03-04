class_name MainDisplay
extends TabContainer


@export_node_path("Viewport") var viewport_path: NodePath


var radiance_cascades_texture_rect: TextureRect:
    get:
        return _radiance_cascades_texture


@onready var _radiance_cascades_texture := %RadianceCascadesTexture as TextureRect
@onready var _default_render_texture_rect := %DefaultRenderTextureRect as TextureRect

@onready var _radiance_cascades_index_tab_index := get_tab_idx_from_control(_radiance_cascades_texture)
@onready var _default_render_index_tab_index := get_tab_idx_from_control(_default_render_texture_rect)


func _ready() -> void:
    var viewport := get_node(viewport_path) as Viewport
    _default_render_texture_rect.texture = viewport.get_texture()


func enable_radiance_cascades(enable: bool) -> void:
    current_tab = _radiance_cascades_index_tab_index if enable else _default_render_index_tab_index
