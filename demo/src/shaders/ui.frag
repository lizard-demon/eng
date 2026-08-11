#version 450

layout(set = 2, binding = 0) uniform sampler2D s_tex;

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_color;

layout(location = 0) out vec4 frag_color;

void main() {
    vec4 mask = texture(s_tex, v_uv);
    frag_color = v_color * mask;
}
