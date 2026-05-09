#version 450
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_col;

layout(location = 0) out vec4 frag_color;

void main() {
    // When you implement texture atlases, your sampling looks like this:
    // vec4 diffuse = texture(s_diffuse, v_diffuse_uv);
    // vec3 lightmap = texture(s_lightmap, v_uv).rgb;
    // frag_color = vec4(diffuse.rgb * (lightmap * 2.0), diffuse.a);

    // Fallback normal-colored shading with a grid overlay
    float grid = max(
        max(1.0 - abs(fract(v_uv.x) - 0.5) * 2.0, 0.0),
        max(1.0 - abs(fract(v_uv.y) - 0.5) * 2.0, 0.0)
    );
    grid = smoothstep(0.9, 1.0, grid);
    
    frag_color = vec4(v_col.rgb * (1.0 - grid * 0.3), 1.0);
}
