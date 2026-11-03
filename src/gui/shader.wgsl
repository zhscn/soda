// Every primitive is an instanced quad in screen pixels: a rectangle with
// rounded corners or an outline, a glyph from the atlas, or a wavy line.
struct Screen {
    size: vec2<f32>,
    atlas: vec2<f32>,
};
@group(0) @binding(0) var<uniform> screen: Screen;
@group(0) @binding(1) var atlas: texture_2d<f32>;
@group(0) @binding(2) var atlas_sampler: sampler;

struct Instance {
    @location(0) rect: vec4<f32>,
    @location(1) uv: vec4<f32>,
    @location(2) color: vec4<f32>,
    // kind, corner radius, line thickness
    @location(3) params: vec4<f32>,
    // left, top, right, bottom: nothing outside shows
    @location(4) clip: vec4<f32>,
};
struct Varying {
    @builtin(position) position: vec4<f32>,
    @location(0) local: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: vec4<f32>,
    @location(3) params: vec4<f32>,
    @location(4) size: vec2<f32>,
    @location(5) clip: vec4<f32>,
};

@vertex
fn vertex(@builtin(vertex_index) index: u32, instance: Instance) -> Varying {
    var corners = array<vec2<f32>, 6>(
        vec2(0.0, 0.0), vec2(1.0, 0.0), vec2(0.0, 1.0),
        vec2(0.0, 1.0), vec2(1.0, 0.0), vec2(1.0, 1.0),
    );
    let corner = corners[index];
    let pixel = instance.rect.xy + corner * instance.rect.zw;
    var out: Varying;
    out.position = vec4(pixel / screen.size * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
    out.local = corner * instance.rect.zw;
    out.uv = mix(instance.uv.xy, instance.uv.zw, corner);
    out.color = instance.color;
    out.params = instance.params;
    out.size = instance.rect.zw;
    out.clip = instance.clip;
    return out;
}

// Distance from a rounded box centered at the origin.
fn rounded(point: vec2<f32>, half: vec2<f32>, radius: f32) -> f32 {
    let q = abs(point) - half + vec2(radius);
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

@fragment
fn fragment(in: Varying) -> @location(0) vec4<f32> {
    if in.position.x < in.clip.x || in.position.y < in.clip.y
        || in.position.x >= in.clip.z || in.position.y >= in.clip.w {
        discard;
    }
    let kind = u32(in.params.x);
    let radius = min(in.params.y, min(in.size.x, in.size.y) * 0.5);
    let center = in.local - in.size * 0.5;
    switch kind {
        // A filled rectangle.
        case 0u: {
            if radius <= 0.0 {
                return in.color;
            }
            let d = rounded(center, in.size * 0.5, radius);
            return vec4(in.color.rgb, in.color.a * clamp(0.5 - d, 0.0, 1.0));
        }
        // A glyph's coverage, in the given color.
        case 1u: {
            let coverage = textureSampleLevel(atlas, atlas_sampler, in.uv, 0.0).a;
            return vec4(in.color.rgb, in.color.a * coverage);
        }
        // A colored glyph, such as an emoji.
        case 2u: {
            let texel = textureSampleLevel(atlas, atlas_sampler, in.uv, 0.0);
            return vec4(texel.rgb, texel.a * in.color.a);
        }
        // A wavy line across the rectangle.
        case 3u: {
            let thickness = in.params.z;
            let amplitude = max(in.size.y * 0.5 - thickness, 0.5);
            let period = max(in.size.y * 2.0, 4.0);
            let curve = in.size.y * 0.5 + amplitude * sin(in.local.x * 6.2831853 / period);
            let d = abs(in.local.y - curve);
            return vec4(in.color.rgb, in.color.a * clamp(thickness * 0.5 + 0.5 - d, 0.0, 1.0));
        }
        // The outline of a rectangle.
        default: {
            let thickness = in.params.z;
            let outer = rounded(center, in.size * 0.5, radius);
            let inner = rounded(center, in.size * 0.5 - vec2(thickness), max(radius - thickness, 0.0));
            let coverage = clamp(0.5 - outer, 0.0, 1.0) * clamp(0.5 + inner, 0.0, 1.0);
            return vec4(in.color.rgb, in.color.a * coverage);
        }
    }
}
