shader_type spatial;
// A surface lit by the lighting its own map compiler baked, and by nothing else.
//
// `unshaded` on purpose. The lightmap IS the lighting -- Source spent a compile
// working out that this luxel is lit magenta by a neon strip six metres away -- and
// running it through Godot's lambert term as well would light it twice and wash the
// colour out. A dynamic light in a surf map has nothing to light: the world is
// static and the only mover is the player.
//
// [b]The translucent twin of `g2g_bsp_lightmapped.gdshader`.[/b] Identical but for
// the ALPHA write at the end, which is the whole difference: writing ALPHA is what
// puts a Godot spatial shader in the transparent pass. A material gets this one only
// when the map's own VMT said `$translucent` or `$alphatest` -- glass, a credits
// panel, an alpha-masked grid -- which is 20 surfaces out of 420 across the eight
// maps. Everything else is opaque and stays that way, for the reason written in the
// other file.
//
// Kept as a copy rather than as an `#include` of a shared body: Godot's `#include`
// cannot be conditional, so the two would still be two files, and a pair that has to
// stay in step is easier to keep in step when both are readable end to end.
//
// [b]Opaque, and the ALPHA write that used to be at the bottom of `fragment()` is
// why.[/b] Godot decides a spatial shader is TRANSPARENT by looking at whether it
// writes ALPHA -- not at what it writes -- so one unconditional `ALPHA = base.a;`
// moved every surface in every imported map into the alpha pass, where depth is not
// written and geometry is sorted per surface rather than per pixel. The result is a
// map that draws through itself: the terrain behind a wall comes out in front of it,
// a concrete floor reads as brown sand, and the whole thing looks like a map whose
// textures are missing. It rendered that way for as long as there have been imported
// maps and no assertion could see it, because every value involved is correct.
//
// The twenty surfaces across the eight maps that really are translucent get
// `g2g_bsp_translucent.gdshader`, which is this file plus the ALPHA write. Two
// shaders, because a shader cannot decide at runtime which pass it belongs to.
render_mode unshaded, cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D lightmap_tex : source_color, filter_linear, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool has_albedo = true;
// How much of the albedo texture one unit of UV is.
//
// 1.0 for a texture the map carried, whose UVs are the ones the mapper placed. For a
// prototype-textured surface the mesh carries UVs in GRID SQUARES -- 64 of the genre's
// units each, the same size everywhere in the game -- and this is one over however many
// squares the installed tile happens to contain, which is the only part of the answer
// that belongs to the image rather than to the world. See tools/bsp_import.py.
uniform float uv_scale = 1.0;
// Baked light is tone-mapped into an 8-bit atlas, so the darks clamp to black.
// `ambient` lifts them back to where a player can see the geometry, which matters
// more in a movement game than fidelity to the original does.
uniform float ambient : hint_range(0.0, 1.0) = 0.10;
uniform float light_boost : hint_range(0.0, 4.0) = 1.35;

void fragment() {
	vec4 base = has_albedo ? texture(albedo_tex, UV * uv_scale) * tint : tint;
	vec3 lm = texture(lightmap_tex, UV2).rgb;
	ALBEDO = base.rgb * (lm * light_boost + ambient);
	ALPHA = base.a;
}
