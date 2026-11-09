shader_type canvas_item;
uniform float pixelation : hint_range(0.001, 0.1) = 0.01;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform float opacity : hint_range(0.0, 1.0) = 1.0;

void fragment() {
    // Calculate pixel dimensions with screen aspect correction
    vec2 viewport_size = vec2(1.0 / SCREEN_PIXEL_SIZE.x, 1.0 / SCREEN_PIXEL_SIZE.y);
    float aspect = float(viewport_size.x) / float(viewport_size.y);
    vec2 pixel_size = vec2(pixelation / aspect, pixelation);

    // Calculate grid aligned UV coordinates
    vec2 coord = SCREEN_UV;
    coord = (floor(coord / pixel_size) + 0.5) * pixel_size;

    float edge_tolerance = 0.001;
    coord = clamp(coord, pixel_size * 0.5 + edge_tolerance, 1.0 - pixel_size * 0.5 - edge_tolerance);

    vec4 color = textureLod(SCREEN_TEXTURE, coord, 0.0);

    vec2 uv_delta = fwidth(SCREEN_UV);
    vec2 edge_dist = smoothstep(vec2(0.0), uv_delta * 2.0, SCREEN_UV) *
                     smoothstep(vec2(0.0), uv_delta * 2.0, vec2(1.0) - SCREEN_UV);
    float edge_factor = edge_dist.x * edge_dist.y;

    // Multiply, don't overwrite — preserve original transparency
    color.a *= opacity * edge_factor;

    COLOR = color;
}