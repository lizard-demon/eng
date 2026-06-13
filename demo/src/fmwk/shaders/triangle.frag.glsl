#version 450

layout(location = 0) in vec3 v_world_pos;
layout(location = 1) in vec4 v_color;
layout(location = 0) out vec4 frag_color;

// ── anti-aliased grid line ────────────────────────────────────────
// fwidth() gives the screen-space derivative so lines stay ~1-2px
// wide at every distance — no aliasing, no thickness drift.
float gridLine(float x, float period, float feather_px) {
    float f  = abs(fract(x / period + 0.5) - 0.5) * period;
    float df = fwidth(f);
    return 1.0 - smoothstep(df, df * feather_px, f);
}

// ── two-scale grid for one planar projection ──────────────────────
float faceGrid(vec2 uv) {
    float g1 = max(gridLine(uv.x, 1.0, 2.0), gridLine(uv.y, 1.0, 2.0));
    float g4 = max(gridLine(uv.x, 4.0, 2.5), gridLine(uv.y, 4.0, 2.5));
    return max(g1 * 0.20, g4 * 0.45);
}

void main() {
    // face normal from screen-space derivatives of world position
    vec3 n    = normalize(cross(dFdx(v_world_pos), dFdy(v_world_pos)));
    float shade = max(dot(n, normalize(vec3(0.3, 1.0, 0.5))), 0.15);

    // triplanar blend — power-8 sharpens seams at 45° surfaces
    vec3 blend = pow(abs(n), vec3(2.0));
    blend /= blend.x + blend.y + blend.z + 1e-5;

    // world-space planar UV for each dominant axis
    vec2 uv_x = v_world_pos.yz;
    vec2 uv_y = v_world_pos.xz;
    vec2 uv_z = v_world_pos.xy;

    // 1-unit checkerboard: ±6% brightness — subtle scale/depth cue
    float ck = mod(floor(uv_x.x) + floor(uv_x.y), 2.0) * blend.x
             + mod(floor(uv_y.x) + floor(uv_y.y), 2.0) * blend.y
             + mod(floor(uv_z.x) + floor(uv_z.y), 2.0) * blend.z;

    // triplanar grid
    float lines = faceGrid(uv_x) * blend.x
                + faceGrid(uv_y) * blend.y
                + faceGrid(uv_z) * blend.z;

    vec3 base = v_color.rgb * (0.94 + ck * 0.12);
    frag_color = vec4(base * shade * (1.0 - lines * 0.55), v_color.a);
}
