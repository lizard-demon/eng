#version 450

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec4 v_color;

layout(location = 0) out vec4 frag_color;

void main() {
    vec3 n = normalize(cross(dFdx(v_world_pos), dFdy(v_world_pos)));
    float shade = max(dot(n, normalize(vec3(0.3, 1.0, 0.5))), 0.15);
    frag_color = vec4(v_color.rgb * shade, v_color.a);
}
