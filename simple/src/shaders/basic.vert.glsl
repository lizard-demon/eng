#version 450
layout(set = 1, binding = 0) uniform UBO { mat4 mvp; };
layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_col;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_col;

void main() {
    gl_Position = mvp * vec4(in_pos, 1.0);
    v_uv = in_uv;
    v_col = in_col;
}
