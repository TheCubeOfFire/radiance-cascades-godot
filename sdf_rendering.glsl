#[compute]
#version 450 core

layout(local_size_x = 16, local_size_y = 16) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D out_image;

struct ObjectData
{
    mat4 inv_model;
    vec3 size;
};

layout(std430, set = 1, binding = 1) buffer restrict readonly ObjectBuffer
{
    ObjectData objects[];
};

layout(set = 1, binding = 0) uniform readonly Transforms
{
    mat4 inv_view;
    mat4 inv_projection;
    vec4 camera_position_world;
};

float sdf_box(vec3 local_coord, vec3 extent)
{
    // Box is symmetric on each axis, take the abs() so calculation is symmetrized around 0
    vec3 abs_coord = abs(local_coord);

    // Signed distance from faces orthogonal to each axis
    vec3 distance_from_face = abs_coord - extent;

    // Compute outside and inside separately as the formula is different

    // max() completely discard inside distance (for each axis) and replace it with 0.
    // Since inside distance is 0, when only one of the components is outside the box bounds for its respective axis,
    // its distance will correctly be the distance to the plane of the face (as the other components are 0).
    // Otherwise, the nearest point of the box is an edge or a corner, and the components will represent the distance
    // from that edge or corner for each axis. The length of the vector will then be the correct distance from the box.
    float outside_distance = length(max(vec3(0.0), distance_from_face));

    // max() is used as a kind of reverse min()
    // The inside distance is the distance from the nearest face. This is obtained by taking the minimum of the absolute
    // distance to a face, which translates to a max() to avoid negating the result twice.
    // min() is used to only account for negative distances.
    float inside_distance = min(0.0, max(distance_from_face.x, max(distance_from_face.y, distance_from_face.z)));

    // Inside distances are negative inside the box and zero elsewhere.
    // Conversely, outside distances are positive outside the box and zero elsewhere.
    // By adding both together, the full range of signed distances is obtained.
    return inside_distance + outside_distance;
}

float sdf_union(float lhs, float rhs)
{
    // does not preserve interior SDF
    return min(lhs, rhs);
}

float sdf_scene(vec4 world_coord)
{
    float sdf = 1E99;
    for (int object_index = 0; object_index < objects.length(); ++object_index)
    {
        ObjectData current_object = objects[object_index];
        vec4 local_coord = current_object.inv_model * world_coord;
        sdf = sdf_union(sdf, sdf_box(local_coord.xyz, current_object.size));
    }
    return sdf;
}

void main()
{
    ivec2 texel_coord = ivec2(gl_GlobalInvocationID.xy);
    vec2 uv = vec2(gl_GlobalInvocationID.xy) / vec2(gl_WorkGroupSize.xy * gl_NumWorkGroups.xy);

    // start at the near plane
    vec4 ndc = vec4(2.0 * uv - 1.0, -1.0, 1.0);
    ndc.y = -ndc.y; // UV y axis is in opposite direction of NDC y axis

    vec4 view_coord = inv_projection * ndc;
    view_coord /= view_coord.w;

    vec4 world_coord = inv_view * view_coord;
    vec4 ray_direction = vec4(normalize(world_coord.xyz - camera_position_world.xyz), 0.0);

    // float sdf = sdf_scene(world_coord);
    //
    // vec4 output_color = vec4(vec3(sdf), 1.0);

    float sdf;

    const int step_count = 64;
    const float hit_distance = 1E-3;

    int step = 0;
    for (step = 0; step < step_count; ++step)
    {
        sdf = sdf_scene(world_coord);
        if (abs(sdf) < hit_distance)
        {
            break;
        }

        world_coord += sdf * ray_direction;
    }

    // display black when sdf is negative and a litte above 0
    // because a ray can't go through a surface with the algorithm above
    // (it tends towards 0)
    float gray_scale = sdf > hit_distance ? 1.0 : float(step) / float(step_count);
    // vec4 output_color = vec4(vec3(step(0.01, sdf)), 1.0);
    vec4 output_color = vec4(vec3(gray_scale), 1.0);

    // vec4 output_color = vec4(ray_direction.xyz, 1.0);

    imageStore(out_image, texel_coord, output_color);
}
