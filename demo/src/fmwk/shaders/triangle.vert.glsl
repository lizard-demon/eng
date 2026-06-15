#version 450

layout(set = 1, binding = 0) uniform UBO { mat4 mvp; };

// Hardware accepts integers (ivec3) natively from Zig's .int3 attribute
layout(location = 0) in ivec3 in_pos;
layout(location = 1) in vec4 in_color;

layout(location = 0) out vec3 v_world_pos;
layout(location = 1) out vec4 v_color;

void main() {
    // 0.0009765625 is exactly 1.0 / 1024.0.
    // The GPU unpacks the fixed-point back to f32 layout space essentially for free.
    vec3 f_pos = vec3(in_pos) * 0.0009765625;
    
    gl_Position = mvp * vec4(f_pos, 1.0);
    v_world_pos = f_pos;
    v_color = in_color;
}
