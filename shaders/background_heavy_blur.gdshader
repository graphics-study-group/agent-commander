shader_type canvas_item;

uniform float blur_scale : hint_range(0.0, 4.0, 0.01) = 2.2;
uniform float dimming : hint_range(0.0, 1.0, 0.01) = 0.35;

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE * blur_scale * 10.0;
	vec4 col = vec4(0.0);
	col += texture(TEXTURE, UV + vec2(-2.0, -2.0) * px) * 0.03;
	col += texture(TEXTURE, UV + vec2( 0.0, -2.0) * px) * 0.05;
	col += texture(TEXTURE, UV + vec2( 2.0, -2.0) * px) * 0.03;
	col += texture(TEXTURE, UV + vec2(-2.0,  0.0) * px) * 0.05;
	col += texture(TEXTURE, UV) * 0.68;
	col += texture(TEXTURE, UV + vec2( 2.0,  0.0) * px) * 0.05;
	col += texture(TEXTURE, UV + vec2(-2.0,  2.0) * px) * 0.03;
	col += texture(TEXTURE, UV + vec2( 0.0,  2.0) * px) * 0.05;
	col += texture(TEXTURE, UV + vec2( 2.0,  2.0) * px) * 0.03;

	col.rgb *= dimming;
	COLOR = vec4(col.rgb, 1.0);
}
