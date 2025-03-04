#[compute]
#version 450 core

layout(local_size_x = 16, local_size_y = 16) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D outImage;

void main()
{
    ivec2 texelCoord = ivec2(gl_GlobalInvocationID.xy);
    vec2 uv = vec2(gl_GlobalInvocationID.xy) / vec2(gl_WorkGroupSize.xy * gl_NumWorkGroups.xy);
    vec4 outputColor = vec4(uv, 0.0, 1.0);
    imageStore(outImage, texelCoord, outputColor);
}
