#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct VideoVertexUniforms {
    // x/y: proportional fit/fill scale, z: rotation in radians, w: horizontal mirror sign
    float4 transform;
    // x: drawable aspect ratio; remaining values reserved for future transforms
    float4 viewport;
};

vertex VertexOut videoQuadVertex(uint vertexID [[vertex_id]],
                                  constant VideoVertexUniforms &uniforms [[buffer(0)]]) {
    float2 positions[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2(-1,  1), float2( 1, -1), float2( 1,  1)
    };
    float2 texCoords[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0)
    };

    float2 position = positions[vertexID] * uniforms.transform.xy;
    float viewportAspect = max(uniforms.viewport.x, 0.0001);
    position.x *= viewportAspect;

    float angle = uniforms.transform.z;
    float sine = sin(angle);
    float cosine = cos(angle);
    position = float2(
        cosine * position.x - sine * position.y,
        sine * position.x + cosine * position.y
    );
    position.x /= viewportAspect;

    float2 texCoord = texCoords[vertexID];
    if (uniforms.transform.w < 0.0) {
        texCoord.x = 1.0 - texCoord.x;
    }

    VertexOut out;
    out.position = float4(position, 0.0, 1.0);
    out.texCoord = texCoord;
    return out;
}

fragment float4 videoQuadFragment(VertexOut in [[stage_in]],
                                   texture2d<float> videoTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    return videoTexture.sample(textureSampler, in.texCoord);
}

// YUV to RGB conversion for FFmpeg frames (BT.709)
fragment float4 yuvToRGBFragment(VertexOut in [[stage_in]],
                                  texture2d<float> yTexture [[texture(0)]],
                                  texture2d<float> uvTexture [[texture(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float2 uv = uvTexture.sample(textureSampler, in.texCoord).rg;

    float u = uv.x - 0.5;
    float v = uv.y - 0.5;

    float r = y + 1.5748 * v;
    float g = y - 0.1873 * u - 0.4681 * v;
    float b = y + 1.8556 * u;

    return float4(r, g, b, 1.0);
}

float glitchHash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

float2 clampUV(float2 uv) {
    return clamp(uv, float2(0.0), float2(1.0));
}

float luminance(float3 color) {
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// MARK: - Master Output blend modes
// mode: 0=Cut, 1=Crossfade, 2=Addition, 3=Wipe, 4=Glitch, 5=Prism, 6=Shatter, 7=Bloom,
//       8=Echo Trail, 9=Film Burn, 10=Datamosh, 12=Luma Melt, 13=Venetian,
//       14=Liquid Glass, 15=Strobe Cut, 17=Pixel Sort, 18=Solarize, 19=Tunnel, 20=Luma Melt V,
//       21=Projection, 26=Panel Snap, 27=Impact Cut, 29=Panel Slide

fragment float4 masterBlendFragment(VertexOut in [[stage_in]],
                                     texture2d<float> textureA [[texture(0)]],
                                     texture2d<float> textureB [[texture(1)]],
                                     constant float &crossfade [[buffer(1)]],
                                     constant int &blendMode [[buffer(2)]],
                                     constant float &opacity [[buffer(3)]],
                                     constant float &transitionDirection [[buffer(4)]],
                                     constant float &transitionOrigin [[buffer(5)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 a = textureA.sample(textureSampler, in.texCoord);
    float4 b = textureB.sample(textureSampler, in.texCoord);

    float4 result;
    if (blendMode == 0) {
        result = crossfade < 0.5 ? a : b;
    } else if (blendMode == 1) {
        result = mix(a, b, crossfade);
    } else if (blendMode == 2) {
        // Addition — 0→50: A→A+B, 50→100: A+B→B
        float4 blended = saturate(a + b);
        if (crossfade < 0.5) {
            result = mix(a, blended, crossfade * 2.0);
        } else {
            result = mix(blended, b, (crossfade - 0.5) * 2.0);
        }
    } else if (blendMode == 3) {
        // Wipe — horizontal hard edge sweep with soft feather
        float edge = smoothstep(crossfade - 0.003, crossfade + 0.003, in.texCoord.x);
        result = mix(b, a, edge);
    } else if (blendMode == 4) {
        // Glitch - controlled signal shear with sparse digital breakup.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;

        float slice = floor(uv.y * 32.0);
        float beat = floor(t * 12.0);
        float n = glitchHash(float2(slice, beat));
        float activeBand = step(0.72, n);
        float wave = sin((uv.y * 42.0) + (t * 21.0) + (n * 6.2831853));
        float sliceShift = (n - 0.5) * 0.085 * impact * activeBand + wave * 0.0035 * impact;

        float2 uvA = clampUV(uv - float2(sliceShift * 0.55, 0.0));
        float2 uvB = clampUV(uv + float2(sliceShift, 0.0));
        float2 rgbSplit = float2((0.003 + 0.011 * impact) * sign(n - 0.5), 0.0);

        float4 glitchA;
        glitchA.r = textureA.sample(textureSampler, clampUV(uvA + rgbSplit)).r;
        glitchA.g = textureA.sample(textureSampler, uvA).g;
        glitchA.b = textureA.sample(textureSampler, clampUV(uvA - rgbSplit)).b;
        glitchA.a = a.a;

        float4 glitchB;
        glitchB.r = textureB.sample(textureSampler, clampUV(uvB - rgbSplit)).r;
        glitchB.g = textureB.sample(textureSampler, uvB).g;
        glitchB.b = textureB.sample(textureSampler, clampUV(uvB + rgbSplit)).b;
        glitchB.a = b.a;

        float diagonal = uv.x * 0.82 + (1.0 - uv.y) * 0.18 + sliceShift * 0.65;
        float gateWidth = 0.070 + impact * 0.030;
        float gate = 1.0 - smoothstep(t - gateWidth, t + gateWidth, diagonal);
        float4 base = mix(glitchA, glitchB, gate);

        float edge = 1.0 - smoothstep(0.0, 0.024 + impact * 0.020, abs(diagonal - t));
        float scanline = smoothstep(0.78, 1.0, fract(uv.y * 118.0 + t * 11.0)) * 0.5;
        float2 block = floor(uv * float2(96.0, 54.0));
        float packet = step(0.987 - impact * 0.020, glitchHash(block + float2(beat, slice)));
        float bandFlash = activeBand * smoothstep(0.18, 0.92, impact) * 0.10;

        float3 color = base.rgb;
        color += edge * float3(0.18, 0.72, 1.0) * (0.24 + impact * 0.34);
        color += scanline * impact * 0.035;
        color += packet * impact * float3(0.42, 0.62, 0.88);
        color += bandFlash;

        result = float4(saturate(color), base.a);
    } else if (blendMode == 5) {
        // Prism - angled glass planes with restrained spectral refraction.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;

        float diagonal = uv.x * 0.72 + (1.0 - uv.y) * 0.38;
        float sweep = 1.0 - smoothstep(t - 0.10, t + 0.10, diagonal);
        float planeA = 1.0 - smoothstep(0.0, 0.020 + impact * 0.012, abs(fract(diagonal * 4.0 - t * 1.65) - 0.5));
        float planeB = 1.0 - smoothstep(0.0, 0.018 + impact * 0.010, abs(fract((uv.x + uv.y * 0.42) * 5.5 + t * 0.9) - 0.5));
        float glass = saturate(planeA * 0.55 + planeB * 0.35);

        float wobble = sin((uv.x - uv.y) * 18.0 + t * 9.0) * 0.004 * impact;
        float2 normal = normalize(float2(0.78, -0.62));
        float2 tangent = float2(-normal.y, normal.x);
        float refractAmount = (0.006 + glass * 0.032) * impact + wobble;
        float2 split = normal * refractAmount + tangent * (glass - 0.5) * 0.010 * impact;
        float2 drift = tangent * (sweep - 0.5) * impact * 0.020;

        float4 prismA;
        prismA.r = textureA.sample(textureSampler, clampUV(uv + drift + split * 1.25)).r;
        prismA.g = textureA.sample(textureSampler, clampUV(uv + drift + split * 0.18)).g;
        prismA.b = textureA.sample(textureSampler, clampUV(uv + drift - split * 0.95)).b;
        prismA.a = a.a;

        float4 prismB;
        prismB.r = textureB.sample(textureSampler, clampUV(uv - drift - split * 0.95)).r;
        prismB.g = textureB.sample(textureSampler, clampUV(uv - drift - split * 0.18)).g;
        prismB.b = textureB.sample(textureSampler, clampUV(uv - drift + split * 1.35)).b;
        prismB.a = b.a;

        float edge = 1.0 - smoothstep(0.0, 0.030 + impact * 0.020, abs(diagonal - t));
        float highlight = saturate(edge * 0.72 + glass * 0.26);
        float sparkle = step(0.992 - impact * 0.018, glitchHash(floor(uv * float2(120.0, 68.0)) + float2(t * 13.0)));
        float3 color = mix(prismA.rgb, prismB.rgb, sweep);
        color += highlight * float3(0.34, 0.78, 1.08) * (0.28 + impact * 0.34);
        color += glass * float3(0.18, 0.02, 0.28) * impact * 0.16;
        color += sparkle * impact * float3(0.72, 0.38, 0.95);
        result = float4(saturate(color), mix(prismA.a, prismB.a, sweep));
    } else if (blendMode == 6) {
        // Shatter - angled glass facets sliding through the transition.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float2 skew = float2(uv.x + uv.y * 0.38, uv.y - uv.x * 0.18);
        float2 grid = float2(12.0, 7.0);
        float2 cell = floor(skew * grid);
        float2 local = fract(skew * grid);
        float n = glitchHash(cell);
        float2 cellCenter = (cell + float2(0.5)) / grid;
        float2 facetCenter = float2(cellCenter.x - cellCenter.y * 0.38, cellCenter.y + cellCenter.x * 0.18);
        float2 dir = normalize(facetCenter - float2(0.5) + float2(0.001));

        float shardOrder = facetCenter.x * 0.64 + (1.0 - facetCenter.y) * 0.24 + n * 0.20;
        float gate = 1.0 - smoothstep(t - 0.085, t + 0.085, shardOrder);
        float2 tangent = float2(-dir.y, dir.x);
        float2 offset = (dir * (0.038 + n * 0.055) + tangent * (n - 0.5) * 0.030) * impact;

        float4 shardA = textureA.sample(textureSampler, clampUV(uv - offset));
        float4 shardB = textureB.sample(textureSampler, clampUV(uv + offset * 0.58));
        float facetEdgeX = 1.0 - smoothstep(0.0, 0.035 + impact * 0.015, min(local.x, 1.0 - local.x));
        float facetEdgeY = 1.0 - smoothstep(0.0, 0.035 + impact * 0.015, min(local.y, 1.0 - local.y));
        float edge = saturate((facetEdgeX + facetEdgeY) * 0.34) * impact;
        float glint = edge * (0.35 + 0.65 * n);
        float3 color = mix(shardA.rgb, shardB.rgb, gate);
        color += glint * float3(0.55, 0.72, 0.95);
        color -= edge * 0.045;
        result = float4(saturate(color), mix(shardA.a, shardB.a, gate));
    } else if (blendMode == 7) {
        // Bloom - soft optical flare with a warm highlight rolloff.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float2 center = float2(0.5);
        float2 ray = uv - center;
        float2 zoomA = center + ray * (1.0 + impact * 0.055);
        float2 zoomB = center + ray * (1.0 - impact * 0.075);

        float4 softA = textureA.sample(textureSampler, clampUV(zoomA));
        float4 softB = textureB.sample(textureSampler, clampUV(zoomB));
        float2 blur = normalize(ray + float2(0.001)) * (0.006 + impact * 0.018);
        float3 glowA = textureA.sample(textureSampler, clampUV(zoomA + blur)).rgb
            + textureA.sample(textureSampler, clampUV(zoomA - blur)).rgb;
        float3 glowB = textureB.sample(textureSampler, clampUV(zoomB + blur)).rgb
            + textureB.sample(textureSampler, clampUV(zoomB - blur)).rgb;
        glowA *= 0.5;
        glowB *= 0.5;

        float4 base = mix(softA, softB, t);
        float3 glow = mix(glowA, glowB, t);
        float luma = dot(glow, float3(0.2126, 0.7152, 0.0722));
        float bloom = smoothstep(0.45, 1.0, luma) * impact;
        float radial = 1.0 - smoothstep(0.08, 0.84, length(ray));
        float streak = pow(1.0 - smoothstep(0.0, 0.42, abs(ray.y + ray.x * 0.13)), 3.0);
        float pulse = smoothstep(0.10, 0.92, impact);

        float3 color = base.rgb;
        color += glow * bloom * 0.32;
        color += float3(1.0, 0.78, 0.48) * pulse * radial * 0.16;
        color += float3(0.52, 0.68, 1.0) * pulse * streak * 0.055;
        color = color / (color + float3(0.18));
        result = float4(saturate(color), base.a);
    } else if (blendMode == 8) {
        // Echo Trail - restrained temporal echo simulated with spatial afterimages.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float2 drift = float2(0.030 + t * 0.040, -0.012) * impact;

        float3 trail = a.rgb * 0.56;
        trail += textureA.sample(textureSampler, clampUV(uv - drift * 0.75)).rgb * 0.24;
        trail += textureA.sample(textureSampler, clampUV(uv - drift * 1.55)).rgb * 0.14;
        trail += textureA.sample(textureSampler, clampUV(uv - drift * 2.45)).rgb * 0.06;

        float2 leadUv = clampUV(uv + drift * 0.24);
        float4 leadB = textureB.sample(textureSampler, leadUv);
        float echoCoord = uv.x * 0.55 + (1.0 - uv.y) * 0.18;
        float echoReveal = smoothstep(echoCoord - 0.12, echoCoord + 0.12, t);
        float3 color = mix(trail, leadB.rgb, max(t, echoReveal * 0.82));
        color += impact * 0.045 * float3(0.36, 0.55, 0.9);
        result = float4(saturate(color), mix(a.a, leadB.a, t));
    } else if (blendMode == 9) {
        // Film Burn - warm organic flare crawling across the frame.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float grain = glitchHash(floor(uv * float2(90.0, 52.0)) + float2(floor(t * 24.0)));
        float edgeCoord = uv.x * 0.74 + (1.0 - uv.y) * 0.30 + (grain - 0.5) * 0.045;
        float reveal = smoothstep(edgeCoord - 0.16, edgeCoord + 0.16, t);
        float burnEdge = 1.0 - smoothstep(0.0, 0.085 + impact * 0.040, abs(edgeCoord - t));
        float halo = 1.0 - smoothstep(0.0, 0.22, abs(edgeCoord - t));

        float3 color = mix(a.rgb, b.rgb, reveal);
        color += burnEdge * float3(1.0, 0.45, 0.12) * (0.34 + impact * 0.36);
        color += halo * float3(0.95, 0.72, 0.42) * impact * 0.16;
        color += (grain - 0.5) * impact * 0.035;
        result = float4(saturate(color), mix(a.a, b.a, reveal));
    } else if (blendMode == 10) {
        // Datamosh - compressed block drift without destroying legibility.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float2 block = floor(uv * float2(28.0, 16.0));
        float n = glitchHash(block + floor(t * 10.0));
        float2 flow = float2(n - 0.5, glitchHash(block + 19.0) - 0.5);
        float2 smear = flow * (0.020 + 0.070 * impact);
        float revealCoord = uv.x * 0.70 + uv.y * 0.15 + n * 0.20;
        float reveal = smoothstep(revealCoord - 0.10, revealCoord + 0.10, t);

        float4 moshedA = textureA.sample(textureSampler, clampUV(uv - smear * (1.0 - t)));
        float4 moshedB = textureB.sample(textureSampler, clampUV(uv + smear * t * 0.75));
        float blockEdge = step(0.94, fract(uv.x * 28.0)) * step(0.18, impact) * 0.05;
        float3 color = mix(moshedA.rgb, moshedB.rgb, reveal);
        color = mix(color, floor(color * 28.0) / 28.0, impact * 0.10);
        color += blockEdge;
        result = float4(saturate(color), mix(moshedA.a, moshedB.a, reveal));
    } else if (blendMode == 12) {
        // Luma Melt - bright details liquify first, then pull the frame down.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float lum = luminance(a.rgb);
        float melt = pow(lum, 0.72) * 0.62 + (1.0 - uv.y) * 0.30 + sin(uv.x * 18.0 + t * 7.0) * 0.035;
        float reveal = smoothstep(melt - 0.12, melt + 0.12, t);
        float drip = reveal * impact * (0.020 + lum * 0.085);

        float4 meltA = textureA.sample(textureSampler, clampUV(uv + float2(0.0, drip)));
        float4 meltB = textureB.sample(textureSampler, clampUV(uv - float2(0.0, drip * 0.35)));
        float edge = 1.0 - smoothstep(0.0, 0.055, abs(melt - t));
        float3 color = mix(meltA.rgb, meltB.rgb, reveal);
        color += edge * impact * float3(0.75, 0.62, 0.38) * 0.18;
        result = float4(saturate(color), mix(meltA.a, meltB.a, reveal));
    } else if (blendMode == 20) {
        // Luma Melt V - the same luminance melt, flowing sideways.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float lum = luminance(a.rgb);
        float melt = pow(lum, 0.72) * 0.62 + uv.x * 0.30 + sin(uv.y * 18.0 + t * 7.0) * 0.035;
        float reveal = smoothstep(melt - 0.12, melt + 0.12, t);
        float drip = reveal * impact * (0.020 + lum * 0.085);

        float4 meltA = textureA.sample(textureSampler, clampUV(uv + float2(-drip, 0.0)));
        float4 meltB = textureB.sample(textureSampler, clampUV(uv + float2(drip * 0.35, 0.0)));
        float edge = 1.0 - smoothstep(0.0, 0.055, abs(melt - t));
        float3 color = mix(meltA.rgb, meltB.rgb, reveal);
        color += edge * impact * float3(0.75, 0.62, 0.38) * 0.18;
        result = float4(saturate(color), mix(meltA.a, meltB.a, reveal));
    } else if (blendMode == 13) {
        // Venetian - elegant slats with staggered timing and soft bevels.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float slatCount = 18.0;
        float slat = floor((uv.x + uv.y * 0.10) * slatCount);
        float local = fract((uv.x + uv.y * 0.10) * slatCount);
        float offset = glitchHash(float2(slat, 4.0)) * 0.22;
        float reveal = smoothstep((slat / slatCount) * 0.72 + offset - 0.08,
                                  (slat / slatCount) * 0.72 + offset + 0.08,
                                  t);
        float bevel = (1.0 - smoothstep(0.0, 0.08, min(local, 1.0 - local))) * impact;
        float2 shift = float2((reveal - 0.5) * 0.020 * impact, 0.0);
        float4 va = textureA.sample(textureSampler, clampUV(uv - shift));
        float4 vb = textureB.sample(textureSampler, clampUV(uv + shift));
        float3 color = mix(va.rgb, vb.rgb, reveal);
        color += bevel * float3(0.42, 0.52, 0.68) * 0.16;
        result = float4(saturate(color), mix(va.a, vb.a, reveal));
    } else if (blendMode == 14) {
        // Liquid Glass - viscous refraction with a clean diagonal reveal.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float waveA = sin(uv.y * 16.0 + t * 5.5) + sin((uv.x + uv.y) * 11.0 - t * 4.0);
        float waveB = sin(uv.x * 23.0 - t * 7.0) * 0.5;
        float2 refract = float2(waveA, waveB) * (0.006 + impact * 0.024);
        float diagonal = uv.x * 0.62 + (1.0 - uv.y) * 0.30 + waveA * 0.012;
        float reveal = smoothstep(t - 0.12, t + 0.12, diagonal);

        float4 glassA = textureA.sample(textureSampler, clampUV(uv + refract));
        float4 glassB = textureB.sample(textureSampler, clampUV(uv - refract * 0.75));
        float caustic = pow(abs(sin((uv.x - uv.y) * 28.0 + t * 8.0)), 12.0) * impact;
        float3 color = mix(glassA.rgb, glassB.rgb, 1.0 - reveal);
        color += caustic * float3(0.34, 0.62, 0.82) * 0.10;
        result = float4(saturate(color), mix(glassA.a, glassB.a, 1.0 - reveal));
    } else if (blendMode == 15) {
        // Strobe Cut - tasteful rhythmic A/B hits before the final landing.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float window = smoothstep(0.14, 0.28, t) * (1.0 - smoothstep(0.72, 0.86, t));
        float pulse = step(0.5, fract(t * 8.0));
        float centeredPulse = mix(0.18, 0.82, pulse);
        float gate = mix(t, centeredPulse, window * 0.70);
        float flash = pow(impact, 5.0) * 0.18;
        float3 color = mix(a.rgb, b.rgb, gate);
        color += flash * float3(0.82, 0.88, 1.0);
        result = float4(saturate(color), mix(a.a, b.a, gate));
    } else if (blendMode == 21) {
        // Projection - incoming clip ghosts appear as analog 24-step future-frames.
        float t = clamp(crossfade, 0.0, 1.0);
        float2 uv = in.texCoord;
        float origin = clamp(transitionOrigin, 0.0, 1.0);
        float forward = step(0.0, transitionDirection);
        float travel = abs(t - origin);
        float travelRange = mix(max(origin, 0.001), max(1.0 - origin, 0.001), forward);
        float sweepProgress = clamp(travel / travelRange, 0.0, 1.0);
        float easedSweep = smoothstep(0.0, 1.0, sweepProgress);
        float frame = floor((origin + easedSweep * mix(-origin, 1.0 - origin, forward)) * 24.0);
        float stepped = min(frame / 23.0, 1.0);
        float subframe = fract(easedSweep * 24.0);
        float impact = sin(easedSweep * 3.14159265);

        float2 motion = normalize(float2(-0.72, 0.18));
        float directionSign = mix(-1.0, 1.0, forward);
        float2 snap = motion * directionSign * (subframe - 0.5) * 0.010 * impact;
        float2 futureStep = motion * (0.032 + (1.0 - sweepProgress) * 0.050);
        float activeMotion = smoothstep(0.004, 0.055, travel);
        float sideRight = smoothstep(origin - 0.18, origin + 0.18, uv.x);
        float sideLeft = 1.0 - sideRight;
        float sideMask = mix(sideLeft, sideRight, forward);
        float oneSidedMask = sideMask * activeMotion;

        float baseLum = luminance(a.rgb);
        float melt = pow(baseLum, 0.72) * 0.62 + (1.0 - uv.y) * 0.30 + sin(uv.x * 18.0 + easedSweep * 7.0) * 0.035;
        float meltReveal = smoothstep(melt - 0.12, melt + 0.12, t);
        float meltDrip = meltReveal * impact * (0.012 + baseLum * 0.050);
        float4 baseA = textureA.sample(textureSampler, clampUV(uv + float2(0.0, meltDrip) - snap * 0.22));
        float4 realB = textureB.sample(textureSampler, clampUV(uv - float2(0.0, meltDrip * 0.30) + snap));
        float meltEdge = 1.0 - smoothstep(0.0, 0.050, abs(melt - t));
        float3 baseColor = mix(baseA.rgb, realB.rgb, meltReveal);
        baseColor += meltEdge * impact * float3(0.28, 0.48, 0.88) * 0.10;
        float baseAlpha = mix(baseA.a, realB.a, meltReveal);

        float ghostWeight = smoothstep(0.02, 0.20, sweepProgress)
            * (1.0 - smoothstep(0.82, 1.0, sweepProgress))
            * (0.40 + impact * 0.44)
            * oneSidedMask;

        float2 edgeXOffset = float2(0.0026, 0.0);
        float2 edgeYOffset = float2(0.0, 0.0026);
        float2 layerOffset1 = futureStep * 0.42;
        float2 layerOffset2 = futureStep * 0.92 + float2(0.0045, -0.0015) * directionSign;
        float2 layerOffset3 = futureStep * 1.55 + float2(-0.0035, 0.0040) * directionSign;
        float2 layerOffset4 = futureStep * 2.25 + float2(0.0020, 0.0070) * directionSign;

        float3 layer1 = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset1)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset1)).rgb,
            forward
        );
        float3 layer1X = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset1 + edgeXOffset)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset1 + edgeXOffset)).rgb,
            forward
        );
        float3 layer1Y = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset1 + edgeYOffset)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset1 + edgeYOffset)).rgb,
            forward
        );
        float outline1 = smoothstep(0.022, 0.14, abs(luminance(layer1) - luminance(layer1X)) + abs(luminance(layer1) - luminance(layer1Y)));

        float3 layer2 = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset2)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset2)).rgb,
            forward
        );
        float3 layer2X = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset2 + edgeXOffset)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset2 + edgeXOffset)).rgb,
            forward
        );
        float3 layer2Y = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset2 + edgeYOffset)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset2 + edgeYOffset)).rgb,
            forward
        );
        float outline2 = smoothstep(0.024, 0.16, abs(luminance(layer2) - luminance(layer2X)) + abs(luminance(layer2) - luminance(layer2Y)));

        float3 layer3 = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset3)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset3)).rgb,
            forward
        );
        float3 layer3X = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset3 + edgeXOffset)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset3 + edgeXOffset)).rgb,
            forward
        );
        float3 layer3Y = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset3 + edgeYOffset)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset3 + edgeYOffset)).rgb,
            forward
        );
        float outline3 = smoothstep(0.026, 0.18, abs(luminance(layer3) - luminance(layer3X)) + abs(luminance(layer3) - luminance(layer3Y)));

        float3 layer4 = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset4)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset4)).rgb,
            forward
        );
        float3 layer4X = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset4 + edgeXOffset)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset4 + edgeXOffset)).rgb,
            forward
        );
        float3 layer4Y = mix(
            textureA.sample(textureSampler, clampUV(uv - layerOffset4 + edgeYOffset)).rgb,
            textureB.sample(textureSampler, clampUV(uv + layerOffset4 + edgeYOffset)).rgb,
            forward
        );
        float outline4 = smoothstep(0.030, 0.20, abs(luminance(layer4) - luminance(layer4X)) + abs(luminance(layer4) - luminance(layer4Y)));

        float outlineStack = outline1 * 0.90 + outline2 * 0.70 + outline3 * 0.52 + outline4 * 0.36;

        float linePhase = uv.y * 170.0 + stepped * 5.0;
        float scanline = smoothstep(0.38, 1.0, fract(linePhase)) * 0.34;
        float interlacePhase = fract(uv.y * 260.0 + frame * 0.06);
        float interlace = 1.0 - smoothstep(0.0, 0.10, abs(interlacePhase - 0.5));
        float rowNoise = glitchHash(float2(floor(uv.y * 170.0), frame));
        float tapeNoise = (rowNoise - 0.5) * 0.075 + (glitchHash(floor(uv * float2(96.0, 54.0)) + frame) - 0.5) * 0.035;

        float3 color = baseColor;
        float futureLine = outlineStack * 0.82 + interlace * 0.16 + scanline * 0.08;
        float thinLine = smoothstep(0.46, 0.52, fract(uv.y * 520.0 + frame * 0.11));
        futureLine += thinLine * oneSidedMask * 0.06;
        float3 lineColor = float3(0.48, 0.76, 1.0) * futureLine * ghostWeight;
        color *= 1.0 - interlace * ghostWeight * 0.045;
        color += lineColor;
        color += tapeNoise * ghostWeight * 0.18;
        result = float4(saturate(color), baseAlpha);
    } else if (blendMode == 17) {
        // Pixel Sort - luminance-driven row displacement that resolves into B.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float row = floor(uv.y * 72.0);
        float rowNoise = glitchHash(float2(row, floor(t * 8.0)));
        float lum = luminance(a.rgb);
        float sortMask = smoothstep(0.28, 0.92, lum + rowNoise * 0.25);
        float offset = sortMask * impact * (rowNoise - 0.35) * 0.18;
        float revealCoord = lum * 0.62 + uv.x * 0.24 + rowNoise * 0.16;
        float reveal = smoothstep(revealCoord - 0.10, revealCoord + 0.10, t);
        float4 sortedA = textureA.sample(textureSampler, clampUV(uv + float2(offset, 0.0)));
        float4 sortedB = textureB.sample(textureSampler, clampUV(uv - float2(offset * 0.45, 0.0)));
        float3 color = mix(sortedA.rgb, sortedB.rgb, reveal);
        color += sortMask * impact * float3(0.12, 0.16, 0.22);
        result = float4(saturate(color), mix(sortedA.a, sortedB.a, reveal));
    } else if (blendMode == 18) {
        // Solarize - polished posterized flash at the crossover.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float diagonal = uv.x * 0.70 + uv.y * 0.22;
        float reveal = smoothstep(diagonal - 0.12, diagonal + 0.12, t);
        float4 base = mix(a, b, reveal);
        float3 solar = 1.0 - abs(1.0 - base.rgb * 2.0);
        float3 poster = floor(base.rgb * 5.0 + 0.5) / 5.0;
        float3 color = mix(base.rgb, mix(solar, poster, 0.36), impact * 0.46);
        color += impact * 0.08 * float3(0.62, 0.48, 0.88);
        result = float4(saturate(color), base.a);
    } else if (blendMode == 19) {
        // Tunnel - cinematic zoom through A into B.
        float t = clamp(crossfade, 0.0, 1.0);
        float impact = sin(t * 3.14159265);
        float2 uv = in.texCoord;
        float2 center = float2(0.5);
        float2 p = uv - center;
        float radius = length(p);
        float angle = atan2(p.y, p.x);
        float twist = impact * (0.28 - radius * 0.20);
        float2 dirA = float2(cos(angle + twist), sin(angle + twist));
        float2 dirB = float2(cos(angle - twist * 0.75), sin(angle - twist * 0.75));
        float2 uvA = clampUV(center + dirA * radius * (1.0 + t * 0.55));
        float2 uvB = clampUV(center + dirB * radius * (0.62 + t * 0.38));
        float reveal = smoothstep(0.12, 0.88, t + (0.38 - radius) * 0.24);
        float4 tunnelA = textureA.sample(textureSampler, uvA);
        float4 tunnelB = textureB.sample(textureSampler, uvB);
        float3 color = mix(tunnelA.rgb, tunnelB.rgb, reveal);
        float rim = smoothstep(0.34, 0.88, radius) * (1.0 - smoothstep(0.88, 1.12, radius));
        color += rim * impact * float3(0.18, 0.30, 0.55) * 0.10;
        result = float4(saturate(color), mix(tunnelA.a, tunnelB.a, reveal));
    } else if (blendMode == 26) {
        // Panel Snap - manga panels flip and reveal in staggered strips.
        float t = clamp(crossfade, 0.0, 1.0);
        float origin = clamp(transitionOrigin, 0.0, 1.0);
        float forward = step(0.0, transitionDirection);
        float travelRange = mix(max(origin, 0.001), max(1.0 - origin, 0.001), forward);
        float progress = clamp(abs(t - origin) / travelRange, 0.0, 1.0);
        float directedT = mix(1.0 - t, t, forward);
        float impact = sin(progress * 3.14159265);
        float2 uv = in.texCoord;
        float2 panelGrid = float2(5.0, 3.0);
        float2 panel = floor(uv * panelGrid);
        float2 local = fract(uv * panelGrid);
        float n = glitchHash(panel);
        float orderBase = (panel.x / (panelGrid.x - 1.0)) * 0.52 + ((panelGrid.y - 1.0 - panel.y) / (panelGrid.y - 1.0)) * 0.28 + n * 0.20;
        float order = mix(1.0 - orderBase, orderBase, forward);
        float panelReveal = smoothstep(order - 0.10, order + 0.10, directedT);
        float flip = sin(panelReveal * 3.14159265);
        float2 hinge = float2((local.x - 0.5) * flip * 0.035 * (n - 0.5), (local.y - 0.5) * flip * 0.026);
        float4 outgoingPanel = mix(
            textureB.sample(textureSampler, clampUV(uv - hinge)),
            textureA.sample(textureSampler, clampUV(uv + hinge)),
            forward
        );
        float4 incomingPanel = mix(
            textureA.sample(textureSampler, clampUV(uv + hinge * 0.7)),
            textureB.sample(textureSampler, clampUV(uv - hinge * 0.7)),
            forward
        );

        float gutterX = 1.0 - smoothstep(0.0, 0.020 + impact * 0.012, min(local.x, 1.0 - local.x));
        float gutterY = 1.0 - smoothstep(0.0, 0.025 + impact * 0.012, min(local.y, 1.0 - local.y));
        float gutter = saturate(gutterX + gutterY) * (0.35 + impact * 0.28);
        float snapLine = 1.0 - smoothstep(0.0, 0.036, abs(order - directedT));

        float3 color = mix(outgoingPanel.rgb, incomingPanel.rgb, panelReveal);
        color = mix(color, color * 0.82 + float3(0.03, 0.035, 0.05), gutter);
        color += snapLine * float3(0.78, 0.86, 1.0) * impact * 0.15;
        result = float4(saturate(color), mix(outgoingPanel.a, incomingPanel.a, panelReveal));
    } else if (blendMode == 27) {
        // Impact Cut - white anime impact frame with black contour and speed marks.
        float t = clamp(crossfade, 0.0, 1.0);
        float origin = clamp(transitionOrigin, 0.0, 1.0);
        float forward = step(0.0, transitionDirection);
        float travelRange = mix(max(origin, 0.001), max(1.0 - origin, 0.001), forward);
        float progress = clamp(abs(t - origin) / travelRange, 0.0, 1.0);
        float directedT = mix(1.0 - t, t, forward);
        float2 uv = in.texCoord;
        float preHit = smoothstep(0.28, 0.38, progress) * (1.0 - smoothstep(0.46, 0.56, progress));
        float mainHit = smoothstep(0.48, 0.52, progress) * (1.0 - smoothstep(0.60, 0.70, progress));
        float afterHit = smoothstep(0.62, 0.70, progress) * (1.0 - smoothstep(0.76, 0.84, progress));
        float hit = saturate(preHit * 0.34 + mainHit + afterHit * 0.24);
        float gate = step(0.5, directedT + (mainHit - preHit) * 0.12);
        float2 shake = float2(
            (glitchHash(float2(floor(progress * 24.0), 2.0)) - 0.5) * 0.018,
            (glitchHash(float2(floor(progress * 24.0), 7.0)) - 0.5) * 0.012
        ) * hit;
        float4 outgoingImpact = mix(
            textureB.sample(textureSampler, clampUV(uv - shake)),
            textureA.sample(textureSampler, clampUV(uv + shake)),
            forward
        );
        float4 incomingImpact = mix(
            textureA.sample(textureSampler, clampUV(uv + shake * 0.62)),
            textureB.sample(textureSampler, clampUV(uv - shake * 0.62)),
            forward
        );
        float4 base = mix(outgoingImpact, incomingImpact, gate);
        float luma = luminance(base.rgb);
        float3 incomingLeft = mix(
            textureA.sample(textureSampler, clampUV(uv - float2(0.0036, 0.0))).rgb,
            textureB.sample(textureSampler, clampUV(uv - float2(0.0036, 0.0))).rgb,
            forward
        );
        float3 incomingRight = mix(
            textureA.sample(textureSampler, clampUV(uv + float2(0.0036, 0.0))).rgb,
            textureB.sample(textureSampler, clampUV(uv + float2(0.0036, 0.0))).rgb,
            forward
        );
        float3 incomingUp = mix(
            textureA.sample(textureSampler, clampUV(uv + float2(0.0, 0.0036))).rgb,
            textureB.sample(textureSampler, clampUV(uv + float2(0.0, 0.0036))).rgb,
            forward
        );
        float3 incomingDown = mix(
            textureA.sample(textureSampler, clampUV(uv - float2(0.0, 0.0036))).rgb,
            textureB.sample(textureSampler, clampUV(uv - float2(0.0, 0.0036))).rgb,
            forward
        );
        float lumaLeft = luminance(incomingLeft);
        float lumaRight = luminance(incomingRight);
        float lumaUp = luminance(incomingUp);
        float lumaDown = luminance(incomingDown);
        float contour = smoothstep(0.045, 0.150, abs(lumaLeft - lumaRight) + abs(lumaUp - lumaDown));
        float shadow = smoothstep(0.18, 0.54, 1.0 - luma) * smoothstep(0.20, 0.96, hit);
        float lineMask = saturate(contour * 1.18 + shadow * 0.34);

        float rowSeed = glitchHash(float2(floor(uv.y * 42.0), floor(progress * 24.0)));
        float speed = smoothstep(0.78, 0.99, fract(uv.y * 116.0 + rowSeed * 6.0 + progress * 10.0));
        float dash = step(0.26 + rowSeed * 0.34, fract(uv.x * (3.5 + rowSeed * 4.0) - progress * 2.0));
        float speedMarks = speed * dash * hit * 0.82;

        float3 impactFrame = float3(1.0) - saturate(lineMask + speedMarks) * float3(0.94);
        float3 color = mix(base.rgb, impactFrame, hit);
        result = float4(saturate(color), base.a);
    } else if (blendMode == 29) {
        // Panel Slide - broad staggered panels slide in without the comic snap.
        float t = clamp(crossfade, 0.0, 1.0);
        float origin = clamp(transitionOrigin, 0.0, 1.0);
        float forward = step(0.0, transitionDirection);
        float travelRange = mix(max(origin, 0.001), max(1.0 - origin, 0.001), forward);
        float progress = clamp(abs(t - origin) / travelRange, 0.0, 1.0);
        float directedT = mix(1.0 - t, t, forward);
        float impact = sin(progress * 3.14159265);
        float2 uv = in.texCoord;
        float panelCount = 5.0;
        float panel = floor((uv.x + uv.y * 0.16) * panelCount);
        float local = fract((uv.x + uv.y * 0.16) * panelCount);
        float n = glitchHash(float2(panel, 13.0));
        float orderBase = panel / (panelCount - 1.0) * 0.72 + n * 0.18;
        float order = mix(1.0 - orderBase, orderBase, forward);
        float panelReveal = smoothstep(order - 0.12, order + 0.12, directedT);
        float slide = (1.0 - panelReveal) * (0.10 + n * 0.055) * impact;
        float2 direction = normalize(float2(0.90, -0.18)) * mix(-1.0, 1.0, forward);
        float4 outgoingSlide = mix(
            textureB.sample(textureSampler, clampUV(uv - direction * slide)),
            textureA.sample(textureSampler, clampUV(uv + direction * slide)),
            forward
        );
        float4 incomingSlide = mix(
            textureA.sample(textureSampler, clampUV(uv + direction * (0.12 - slide) * impact)),
            textureB.sample(textureSampler, clampUV(uv - direction * (0.12 - slide) * impact)),
            forward
        );
        float seam = 1.0 - smoothstep(0.0, 0.034 + impact * 0.010, min(local, 1.0 - local));
        float highlight = 1.0 - smoothstep(0.0, 0.042, abs(order - directedT));

        float3 color = mix(outgoingSlide.rgb, incomingSlide.rgb, panelReveal);
        color *= 1.0 - seam * impact * 0.10;
        color += highlight * float3(0.72, 0.84, 1.0) * impact * 0.12;
        result = float4(saturate(color), mix(outgoingSlide.a, incomingSlide.a, panelReveal));
    } else {
        result = mix(a, b, crossfade);
    }
    return float4(result.rgb * opacity, result.a);
}

// MARK: - Waveform GPU rendering

struct WaveformUniforms {
    float viewWidth;
    float viewHeight;
    int visibleSamples;
    int halfVisible;
    float barWidth;
    float gap;
    int hasBands;
    int markerCount;
    float pos;
    float visibleFraction;
    float cuePoint;
    float rangeStart;  // normalized playback range; -1…2 when unset
    float rangeEnd;
};

vertex VertexOut waveformVertex(uint vertexID [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1, -1), float2( 1, -1), float2(-1,  1),
        float2(-1,  1), float2( 1, -1), float2( 1,  1)
    };
    float2 texCoords[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0)
    };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Returns marker/cue bar color at (x,y) or -1 if fragment is outside the bar.
// triH = triangle height, triHW = half-width at base,
// lineW = half-width of vertical line, fill = fill color, edge = edge color.
float4 markerBar(float x, float y, float viewHeight, float markerX,
                 float triH, float triHW, float lineW,
                 float3 fill, float3 edge) {
    float dx = abs(x - markerX);

    // Top triangle (pointing down from top edge)
    if (y < triH) {
        float w = triHW * (1.0 - y / triH);
        if (dx < w + 1.0) {
            return dx >= w ? float4(edge, 1) : float4(fill, 1);
        }
    }

    // Bottom triangle (pointing up from bottom edge)
    float fromBot = viewHeight - y;
    if (fromBot < triH) {
        float w = triHW * (1.0 - fromBot / triH);
        if (dx < w + 1.0) {
            return dx >= w ? float4(edge, 1) : float4(fill, 1);
        }
    }

    // Vertical line
    if (dx < lineW + 2.0) {
        return dx < lineW ? float4(fill, 1) : float4(edge, 1);
    }

    return float4(-1);  // not a bar fragment
}

// White bracket at a playback range edge, opening toward the playable section.
// direction: +1 for the in point ("["), -1 for the out point ("]").
float4 rangeBracket(float x, float y, float viewHeight, float edgeX, float direction) {
    float inward = (x - edgeX) * direction;
    if (inward < 0.0 || inward >= 7.0) return float4(-1);
    if (inward < 2.0 || y < 2.0 || y > viewHeight - 2.0) return float4(1);
    return float4(-1);
}

fragment float4 waveformFragment(VertexOut in [[stage_in]],
                                  constant WaveformUniforms &u [[buffer(0)]],
                                  constant float *samples [[buffer(1)]],
                                  constant packed_float3 *bands [[buffer(2)]],
                                  constant float *markers [[buffer(3)]],
                                  constant float4 *hotCues [[buffer(4)]]) {
    float x = in.texCoord.x * u.viewWidth;
    float y = in.texCoord.y * u.viewHeight;
    float midY = u.viewHeight * 0.5;
    float3 bg = float3(0.05, 0.05, 0.07);

    // Hot cue entries preserve their slot color; a negative position means unset/disabled.
    for (int slot = 0; slot < 8; slot++) {
        float4 hotCue = hotCues[slot];
        if (hotCue.w < 0.0) continue;
        float offset = (hotCue.w - u.pos) / u.visibleFraction;
        float hx = u.viewWidth * (0.5 + offset);
        float4 c = markerBar(x, y, u.viewHeight, hx, 8.0, 5.0, 2.0,
                              hotCue.rgb, hotCue.rgb * 0.3);
        if (c.a >= 0) return c;
    }

    // Markers — white bar with triangle indicators
    for (int m = 0; m < u.markerCount && m < 16; m++) {
        float offset = (markers[m] - u.pos) / u.visibleFraction;
        float mx = u.viewWidth * (0.5 + offset);
        float4 c = markerBar(x, y, u.viewHeight, mx, 8.0, 5.0, 2.0,
                              float3(0, 0.85, 0), float3(0, 0.3, 0));
        if (c.a >= 0) return c;
    }

    // Cue point — yellow bar with triangle indicators
    if (u.cuePoint >= 0.0) {
        float offset = (u.cuePoint - u.pos) / u.visibleFraction;
        float cx = u.viewWidth * (0.5 + offset);
        float4 c = markerBar(x, y, u.viewHeight, cx, 8.0, 5.0, 1.5,
                              float3(1), float3(0));
        if (c.a >= 0) return c;
    }

    // Playback range edges
    if (u.rangeStart > 0.0) {
        float sx = u.viewWidth * (0.5 + (u.rangeStart - u.pos) / u.visibleFraction);
        float4 c = rangeBracket(x, y, u.viewHeight, sx, 1.0);
        if (c.a >= 0) return c;
    }
    if (u.rangeEnd < 1.0) {
        float ex = u.viewWidth * (0.5 + (u.rangeEnd - u.pos) / u.visibleFraction);
        float4 c = rangeBracket(x, y, u.viewHeight, ex, -1.0);
        if (c.a >= 0) return c;
    }

    // Center line (white at 8% blended over bg)
    if (abs(y - midY) < 0.5) {
        return float4(float3(1) * 0.08 + bg * 0.92, 1.0);
    }

    // Bar index
    int barIdx = int(x / u.barWidth);
    if (barIdx < 0 || barIdx >= u.visibleSamples) {
        return float4(bg, 1.0);
    }

    // Gap between bars
    float barLocalX = x - float(barIdx) * u.barWidth;
    if (u.gap > 0 && (barLocalX < u.gap * 0.5 || barLocalX > u.barWidth - u.gap * 0.5)) {
        return float4(bg, 1.0);
    }

    // Amplitude (buffer pre-padded to visibleSamples length)
    float amplitude = max(samples[barIdx] * midY * 0.92, 0.5);
    if (abs(y - midY) > amplitude) {
        return float4(bg, 1.0);
    }

    bool isPast = barIdx < u.halfVisible;
    float alpha = (y < midY) ? 1.0 : 0.7;
    // Audio outside the playback range never plays; draw it faintly.
    float barPos = u.pos + float(barIdx - u.halfVisible) * u.visibleFraction / float(u.visibleSamples);
    if (barPos < u.rangeStart || barPos > u.rangeEnd) {
        alpha *= 0.3;
    }

    float3 color;
    if (u.hasBands != 0) {
        float3 band = float3(bands[barIdx]);
        float brightness = isPast ? 0.55 : 1.0;
        color = max(band * brightness, float3(0.15 * brightness));
    } else {
        color = isPast ? float3(0.1, 0.35, 0.38) : float3(0.2, 0.65, 0.72);
    }

    // Pre-blend alpha against background (output fully opaque)
    return float4(color * alpha + bg * (1.0 - alpha), 1.0);
}
