#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 modelViewProjectionMatrix;
    float4x4 modelMatrix;
    float4x4 invModelMatrix;
    float3 cameraPositionWorld;
    uint steps;
    float density;
    float brightness;
    uint useAlpha;
    uint useVoxelBlockRendering;
    uint outputStraightAlpha;
    uint smoothEdges;
    float layerOpacity;
    uint matteDiscardTransparent;
    uint trackMatteEnabled;
    uint trackMatteUseAlpha;
    float trackMatteOpacity;
    float4x4 trackMatteInvModelMatrix;
    float4 volumeUVScale;
    float4 volumeUVOffset;
};

struct VSOut {
    float4 position [[position]];
    float3 localPos;
    float3 worldPos;
};

struct PlaneOverlayVSOut {
    float4 position [[position]];
};

struct MeshSurfaceVertex {
    float3 position;
    float3 normal;
};

struct MeshSurfaceVSOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normalWorld;
};

struct BackgroundUniforms {
    float3 color;
    float tileSize;
};

struct BackgroundVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex BackgroundVSOut cameraBackgroundVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    BackgroundVSOut out;
    float2 p = positions[vid];
    out.position = float4(p, 0.999, 1.0);
    out.uv = p * 0.5 + 0.5;
    return out;
}

fragment float4 cameraCheckerboardFragment(BackgroundVSOut in [[stage_in]],
                                           constant BackgroundUniforms &u [[buffer(0)]]) {
    float tile = max(u.tileSize, 2.0);
    float2 cell = floor(in.position.xy / tile);
    float checker = fmod(cell.x + cell.y, 2.0);
    float3 light = float3(0.82);
    float3 dark = float3(0.56);
    float3 base = mix(light, dark, checker);
    float3 color = mix(base, u.color, 0.18);
    return float4(color, 1.0);
}

vertex VSOut volumeVertex(uint vid [[vertex_id]],
                          const device float3 *positions [[buffer(0)]],
                          constant Uniforms &u [[buffer(1)]]) {
    VSOut out;
    float3 p = positions[vid];
    out.localPos = p;

    float4 world = u.modelMatrix * float4(p, 1.0);
    out.worldPos = world.xyz;
    out.position = u.modelViewProjectionMatrix * float4(p, 1.0);
    return out;
}

vertex PlaneOverlayVSOut planeOverlayVertex(uint vid [[vertex_id]],
                                            const device float3 *positions [[buffer(0)]],
                                            constant Uniforms &u [[buffer(1)]]) {
    PlaneOverlayVSOut out;
    out.position = u.modelViewProjectionMatrix * float4(positions[vid], 1.0);
    return out;
}

vertex MeshSurfaceVSOut meshSurfaceVertex(uint vid [[vertex_id]],
                                          const device MeshSurfaceVertex *vertices [[buffer(0)]],
                                          constant Uniforms &u [[buffer(1)]]) {
    MeshSurfaceVertex meshVertex = vertices[vid];
    float4 world = u.modelMatrix * float4(meshVertex.position, 1.0);

    MeshSurfaceVSOut out;
    out.position = u.modelViewProjectionMatrix * float4(meshVertex.position, 1.0);
    out.worldPos = world.xyz;
    out.normalWorld = normalize((u.modelMatrix * float4(meshVertex.normal, 0.0)).xyz);
    return out;
}

fragment float4 planeOverlayFragment(PlaneOverlayVSOut in [[stage_in]]) {
    return float4(1.0, 0.82, 0.0, 0.28);
}

fragment float4 meshSurfaceFragment(MeshSurfaceVSOut in [[stage_in]],
                                    constant Uniforms &u [[buffer(0)]]) {
    float3 normal = normalize(in.normalWorld);
    float3 viewDir = normalize(u.cameraPositionWorld - in.worldPos);
    normal = faceforward(normal, -viewDir, normal);

    float3 lightA = normalize(float3(-0.35, 0.72, 0.58));
    float3 lightB = normalize(float3(0.45, -0.25, 0.88));
    float diffuse = 0.18
        + 0.58 * saturate(dot(normal, lightA))
        + 0.24 * saturate(dot(normal, lightB));
    float rim = pow(saturate(1.0 - dot(normal, viewDir)), 2.4) * 0.22;

    float3 base = float3(0.78, 0.80, 0.82);
    float3 color = base * diffuse + float3(rim);
    return float4(clamp(color, 0.0, 1.0), 1.0);
}

static bool rayBoxIntersect(float3 ro, float3 rd, thread float &tmin, thread float &tmax) {
    float3 boxMin = float3(-0.5, -0.5, -0.5);
    float3 boxMax = float3( 0.5,  0.5,  0.5);

    float3 invR = 1.0 / rd;
    float3 tbot = (boxMin - ro) * invR;
    float3 ttop = (boxMax - ro) * invR;
    float3 tsmaller = min(tbot, ttop);
    float3 tbigger = max(tbot, ttop);

    tmin = max(max(tsmaller.x, tsmaller.y), tsmaller.z);
    tmax = min(min(tbigger.x, tbigger.y), tbigger.z);

    return tmax >= max(tmin, 0.0);
}

static float computeSampleAlpha(float4 sampleColor, constant Uniforms &u) {
    if (u.useAlpha != 0u) {
        return sampleColor.a;
    }
    return max(sampleColor.r, max(sampleColor.g, sampleColor.b));
}

static float4 sampleVolumeSmooth(texture3d<float> volumeTex,
                                 sampler samp,
                                 float3 uvw,
                                 constant Uniforms &u) {
    float4 center = volumeTex.sample(samp, uvw);
    if (u.smoothEdges == 0u) {
        return center;
    }

    float3 texel = 1.0 / float3(
        max(float(volumeTex.get_width()), 1.0),
        max(float(volumeTex.get_height()), 1.0),
        max(float(volumeTex.get_depth()), 1.0)
    );

    float4 sum = center * 0.50;
    sum += volumeTex.sample(samp, clamp(uvw + float3(texel.x, 0.0, 0.0), 0.0, 1.0)) * (0.50 / 6.0);
    sum += volumeTex.sample(samp, clamp(uvw - float3(texel.x, 0.0, 0.0), 0.0, 1.0)) * (0.50 / 6.0);
    sum += volumeTex.sample(samp, clamp(uvw + float3(0.0, texel.y, 0.0), 0.0, 1.0)) * (0.50 / 6.0);
    sum += volumeTex.sample(samp, clamp(uvw - float3(0.0, texel.y, 0.0), 0.0, 1.0)) * (0.50 / 6.0);
    sum += volumeTex.sample(samp, clamp(uvw + float3(0.0, 0.0, texel.z), 0.0, 1.0)) * (0.50 / 6.0);
    sum += volumeTex.sample(samp, clamp(uvw - float3(0.0, 0.0, texel.z), 0.0, 1.0)) * (0.50 / 6.0);
    return sum;
}

static float4 sampleVolumeArrayLinear(texture2d_array<float> volumeTex,
                                      sampler samp,
                                      float3 uvw) {
    uint depth = max(volumeTex.get_array_size(), 1u);
    if (depth <= 1u) {
        return volumeTex.sample(samp, clamp(uvw.xy, 0.0, 1.0), 0u);
    }

    float z = clamp(uvw.z, 0.0, 1.0) * float(depth) - 0.5;
    z = clamp(z, 0.0, float(depth - 1u));
    uint z0 = min(uint(floor(z)), depth - 1u);
    uint z1 = min(z0 + 1u, depth - 1u);
    float f = fract(z);
    float2 xy = clamp(uvw.xy, 0.0, 1.0);
    float4 a = volumeTex.sample(samp, xy, z0);
    float4 b = volumeTex.sample(samp, xy, z1);
    return mix(a, b, f);
}

static float4 sampleVolumeArraySmooth(texture2d_array<float> volumeTex,
                                      sampler samp,
                                      float3 uvw,
                                      constant Uniforms &u) {
    float4 center = sampleVolumeArrayLinear(volumeTex, samp, uvw);
    if (u.smoothEdges == 0u) {
        return center;
    }

    float3 texel = 1.0 / float3(
        max(float(volumeTex.get_width()), 1.0),
        max(float(volumeTex.get_height()), 1.0),
        max(float(volumeTex.get_array_size()), 1.0)
    );

    float4 sum = center * 0.50;
    sum += sampleVolumeArrayLinear(volumeTex, samp, clamp(uvw + float3(texel.x, 0.0, 0.0), 0.0, 1.0)) * (0.50 / 6.0);
    sum += sampleVolumeArrayLinear(volumeTex, samp, clamp(uvw - float3(texel.x, 0.0, 0.0), 0.0, 1.0)) * (0.50 / 6.0);
    sum += sampleVolumeArrayLinear(volumeTex, samp, clamp(uvw + float3(0.0, texel.y, 0.0), 0.0, 1.0)) * (0.50 / 6.0);
    sum += sampleVolumeArrayLinear(volumeTex, samp, clamp(uvw - float3(0.0, texel.y, 0.0), 0.0, 1.0)) * (0.50 / 6.0);
    sum += sampleVolumeArrayLinear(volumeTex, samp, clamp(uvw + float3(0.0, 0.0, texel.z), 0.0, 1.0)) * (0.50 / 6.0);
    sum += sampleVolumeArrayLinear(volumeTex, samp, clamp(uvw - float3(0.0, 0.0, texel.z), 0.0, 1.0)) * (0.50 / 6.0);
    return sum;
}

static float ditherValue(float2 p) {
    float n = fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    return (n - 0.5) / 255.0;
}

static float4 finalizeVolumeColor(float4 premultipliedColor, constant Uniforms &u, float2 pixelPosition) {
    float4 outColor = premultipliedColor;
    float opacity = clamp(u.layerOpacity, 0.0, 1.0);
    outColor.rgb *= opacity;
    outColor.a *= opacity;

    if (u.outputStraightAlpha != 0u) {
        if (outColor.a > 0.0001) {
            outColor.rgb = outColor.rgb / outColor.a;
        } else {
            outColor.rgb = float3(0.0);
        }
    }

    float d = ditherValue(pixelPosition);
    outColor.rgb = clamp(outColor.rgb + d, 0.0, 1.0);
    return clamp(outColor, 0.0, 1.0);
}

static float4 renderContinuous(float3 cameraLocal,
                               float3 rayDir,
                               constant Uniforms &u,
                               texture3d<float> volumeTex,
                               sampler samp,
                               float2 pixelPosition) {
    float tEnter, tExit;
    if (!rayBoxIntersect(cameraLocal, rayDir, tEnter, tExit)) {
        discard_fragment();
    }

    tEnter = max(tEnter, 0.0);

    const uint N = max(u.steps, 8u);
    float len = max(tExit - tEnter, 1e-4);
    float dt = len / float(N);

    float3 pos = cameraLocal + rayDir * tEnter;
    float4 accum = float4(0.0);

    for (uint i = 0; i < N; ++i) {
        float3 uvw = float3(pos.x + 0.5, 1.0 - (pos.y + 0.5), pos.z + 0.5);

        if (all(uvw >= 0.0) && all(uvw <= 1.0)) {
            float4 sampleColor = sampleVolumeSmooth(volumeTex, samp, uvw, u);

            float alpha = computeSampleAlpha(sampleColor, u);
            alpha *= u.density * dt * 8.0;
            alpha = clamp(alpha, 0.0, 1.0);

            float3 rgb = sampleColor.rgb * u.brightness;
            float oneMinusA = 1.0 - accum.a;

            accum.rgb += rgb * alpha * oneMinusA;
            accum.a += alpha * oneMinusA;

            if (accum.a > 0.995) {
                break;
            }
        }

        pos += rayDir * dt;
    }

    return finalizeVolumeColor(float4(accum.rgb, accum.a), u, pixelPosition);
}

static float4 renderContinuousArray(float3 cameraLocal,
                                    float3 rayDir,
                                    constant Uniforms &u,
                                    texture2d_array<float> volumeTex,
                                    sampler samp,
                                    float2 pixelPosition) {
    float tEnter, tExit;
    if (!rayBoxIntersect(cameraLocal, rayDir, tEnter, tExit)) {
        discard_fragment();
    }

    tEnter = max(tEnter, 0.0);

    const uint N = max(u.steps, 8u);
    float len = max(tExit - tEnter, 1e-4);
    float dt = len / float(N);

    float3 pos = cameraLocal + rayDir * tEnter;
    float4 accum = float4(0.0);

    for (uint i = 0; i < N; ++i) {
        float3 uvw = float3(pos.x + 0.5, 1.0 - (pos.y + 0.5), pos.z + 0.5);

        if (all(uvw >= 0.0) && all(uvw <= 1.0)) {
            float4 sampleColor = sampleVolumeArraySmooth(volumeTex, samp, uvw, u);

            float alpha = computeSampleAlpha(sampleColor, u);
            alpha *= u.density * dt * 8.0;
            alpha = clamp(alpha, 0.0, 1.0);

            float3 rgb = sampleColor.rgb * u.brightness;
            float oneMinusA = 1.0 - accum.a;

            accum.rgb += rgb * alpha * oneMinusA;
            accum.a += alpha * oneMinusA;

            if (accum.a > 0.995) {
                break;
            }
        }

        pos += rayDir * dt;
    }

    return finalizeVolumeColor(float4(accum.rgb, accum.a), u, pixelPosition);
}

static uint3 localPosToVoxelCoord(float3 pos, texture3d<float> volumeTex) {
    uint w = volumeTex.get_width();
    uint h = volumeTex.get_height();
    uint d = volumeTex.get_depth();

    float3 uvw = float3(pos.x + 0.5, 1.0 - (pos.y + 0.5), pos.z + 0.5);
    uvw = clamp(uvw, 0.0, 0.999999);

    uint x = min(uint(floor(uvw.x * float(w))), w - 1);
    uint y = min(uint(floor(uvw.y * float(h))), h - 1);
    uint z = min(uint(floor(uvw.z * float(d))), d - 1);
    return uint3(x, y, z);
}

static uint3 localPosToVoxelCoordArray(float3 pos, texture2d_array<float> volumeTex) {
    uint w = volumeTex.get_width();
    uint h = volumeTex.get_height();
    uint d = volumeTex.get_array_size();

    float3 uvw = float3(pos.x + 0.5, 1.0 - (pos.y + 0.5), pos.z + 0.5);
    uvw = clamp(uvw, 0.0, 0.999999);

    uint x = min(uint(floor(uvw.x * float(w))), w - 1);
    uint y = min(uint(floor(uvw.y * float(h))), h - 1);
    uint z = min(uint(floor(uvw.z * float(d))), d - 1);
    return uint3(x, y, z);
}

static float4 renderVoxelBlocks(float3 cameraLocal,
                                float3 rayDir,
                                constant Uniforms &u,
                                texture3d<float> volumeTex,
                                sampler samp,
                                float2 pixelPosition) {
    float tEnter, tExit;
    if (!rayBoxIntersect(cameraLocal, rayDir, tEnter, tExit)) {
        discard_fragment();
    }

    tEnter = max(tEnter, 0.0);

    uint w = volumeTex.get_width();
    uint h = volumeTex.get_height();
    uint d = volumeTex.get_depth();
    uint maxDim = max(w, max(h, d));

    float dt = 0.5 / max(float(maxDim), 1.0);
    float len = max(tExit - tEnter, 1e-4);
    uint N = min(uint(ceil(len / dt)) + 2u, 8192u);

    float3 pos = cameraLocal + rayDir * tEnter;
    float4 accum = float4(0.0);

    int3 lastVoxel = int3(-1, -1, -1);

    for (uint i = 0; i < N; ++i) {
        float3 uvw = float3(pos.x + 0.5, 1.0 - (pos.y + 0.5), pos.z + 0.5);

        if (all(uvw >= 0.0) && all(uvw <= 1.0)) {
            uint3 voxelCoord = localPosToVoxelCoord(pos, volumeTex);
            int3 currentVoxel = int3(voxelCoord);

            if (any(currentVoxel != lastVoxel)) {
                lastVoxel = currentVoxel;

                float4 sampleColor;
                if (u.smoothEdges != 0u) {
                    sampleColor = sampleVolumeSmooth(volumeTex, samp, uvw, u);
                } else {
                    sampleColor = volumeTex.read(voxelCoord);
                }
                float alpha = computeSampleAlpha(sampleColor, u);

                // 体素块模式下，每个体素只累计一次，并适当增强块感
                alpha *= u.density * 1.15;
                alpha = clamp(alpha, 0.0, 1.0);

                if (alpha > 0.001) {
                    float3 rgb = sampleColor.rgb * u.brightness;
                    float oneMinusA = 1.0 - accum.a;

                    accum.rgb += rgb * alpha * oneMinusA;
                    accum.a += alpha * oneMinusA;

                    if (accum.a > 0.995) {
                        break;
                    }
                }
            }
        }

        pos += rayDir * dt;
    }

    return finalizeVolumeColor(float4(accum.rgb, accum.a), u, pixelPosition);
}

static float4 renderVoxelBlocksArray(float3 cameraLocal,
                                     float3 rayDir,
                                     constant Uniforms &u,
                                     texture2d_array<float> volumeTex,
                                     sampler samp,
                                     float2 pixelPosition) {
    float tEnter, tExit;
    if (!rayBoxIntersect(cameraLocal, rayDir, tEnter, tExit)) {
        discard_fragment();
    }

    tEnter = max(tEnter, 0.0);

    uint w = volumeTex.get_width();
    uint h = volumeTex.get_height();
    uint d = volumeTex.get_array_size();
    uint maxDim = max(w, max(h, d));

    float dt = 0.5 / max(float(maxDim), 1.0);
    float len = max(tExit - tEnter, 1e-4);
    uint N = min(uint(ceil(len / dt)) + 2u, 8192u);

    float3 pos = cameraLocal + rayDir * tEnter;
    float4 accum = float4(0.0);

    int3 lastVoxel = int3(-1, -1, -1);

    for (uint i = 0; i < N; ++i) {
        float3 uvw = float3(pos.x + 0.5, 1.0 - (pos.y + 0.5), pos.z + 0.5);

        if (all(uvw >= 0.0) && all(uvw <= 1.0)) {
            uint3 voxelCoord = localPosToVoxelCoordArray(pos, volumeTex);
            int3 currentVoxel = int3(voxelCoord);

            if (any(currentVoxel != lastVoxel)) {
                lastVoxel = currentVoxel;

                float4 sampleColor = u.smoothEdges != 0u
                    ? sampleVolumeArraySmooth(volumeTex, samp, uvw, u)
                    : volumeTex.read(voxelCoord.xy, voxelCoord.z);
                float alpha = computeSampleAlpha(sampleColor, u);

                alpha *= u.density * 1.15;
                alpha = clamp(alpha, 0.0, 1.0);

                if (alpha > 0.001) {
                    float3 rgb = sampleColor.rgb * u.brightness;
                    float oneMinusA = 1.0 - accum.a;

                    accum.rgb += rgb * alpha * oneMinusA;
                    accum.a += alpha * oneMinusA;

                    if (accum.a > 0.995) {
                        break;
                    }
                }
            }
        }

        pos += rayDir * dt;
    }

    return finalizeVolumeColor(float4(accum.rgb, accum.a), u, pixelPosition);
}

static float sampleAlphaAlongRay(float3 cameraLocal,
                                 float3 rayDir,
                                 uint steps,
                                 uint useAlpha,
                                 float opacity,
                                 texture3d<float> volumeTex,
                                 sampler samp) {
    float tEnter, tExit;
    if (!rayBoxIntersect(cameraLocal, rayDir, tEnter, tExit)) {
        return 0.0;
    }

    tEnter = max(tEnter, 0.0);
    const uint N = max(steps, 8u);
    float len = max(tExit - tEnter, 1e-4);
    float dt = len / float(N);
    float3 pos = cameraLocal + rayDir * tEnter;
    float maskAlpha = 0.0;

    for (uint i = 0; i < N; ++i) {
        float3 uvw = float3(pos.x + 0.5, 1.0 - (pos.y + 0.5), pos.z + 0.5);
        if (all(uvw >= 0.0) && all(uvw <= 1.0)) {
            float4 sampleColor = volumeTex.sample(samp, uvw);
            float alpha = useAlpha != 0u
                ? sampleColor.a
                : max(sampleColor.r, max(sampleColor.g, sampleColor.b));
            maskAlpha = max(maskAlpha, alpha);
            if (maskAlpha >= 0.995) {
                break;
            }
        }
        pos += rayDir * dt;
    }

    return maskAlpha * clamp(opacity, 0.0, 1.0);
}

static float sampleAlphaAlongRayArray(float3 cameraLocal,
                                      float3 rayDir,
                                      uint steps,
                                      uint useAlpha,
                                      float opacity,
                                      texture2d_array<float> volumeTex,
                                      sampler samp) {
    float tEnter, tExit;
    if (!rayBoxIntersect(cameraLocal, rayDir, tEnter, tExit)) {
        return 0.0;
    }

    tEnter = max(tEnter, 0.0);
    const uint N = max(steps, 8u);
    float len = max(tExit - tEnter, 1e-4);
    float dt = len / float(N);
    float3 pos = cameraLocal + rayDir * tEnter;
    float maskAlpha = 0.0;

    for (uint i = 0; i < N; ++i) {
        float3 uvw = float3(pos.x + 0.5, 1.0 - (pos.y + 0.5), pos.z + 0.5);
        if (all(uvw >= 0.0) && all(uvw <= 1.0)) {
            float4 sampleColor = sampleVolumeArrayLinear(volumeTex, samp, uvw);
            float alpha = useAlpha != 0u
                ? sampleColor.a
                : max(sampleColor.r, max(sampleColor.g, sampleColor.b));
            maskAlpha = max(maskAlpha, alpha);
            if (maskAlpha >= 0.995) {
                break;
            }
        }
        pos += rayDir * dt;
    }

    return maskAlpha * clamp(opacity, 0.0, 1.0);
}

static float4 renderAlphaMatte(float3 cameraLocal,
                               float3 rayDir,
                               constant Uniforms &u,
                               texture3d<float> volumeTex,
                               sampler samp) {
    float maskAlpha = sampleAlphaAlongRay(
        cameraLocal,
        rayDir,
        u.steps,
        u.useAlpha,
        u.layerOpacity,
        volumeTex,
        samp
    );
    if (maskAlpha <= (1.0 / 255.0)) {
        discard_fragment();
    }
    return float4(maskAlpha, maskAlpha, maskAlpha, maskAlpha);
}

static float4 renderAlphaMatteArray(float3 cameraLocal,
                                    float3 rayDir,
                                    constant Uniforms &u,
                                    texture2d_array<float> volumeTex,
                                    sampler samp) {
    float maskAlpha = sampleAlphaAlongRayArray(
        cameraLocal,
        rayDir,
        u.steps,
        u.useAlpha,
        u.layerOpacity,
        volumeTex,
        samp
    );
    if (maskAlpha <= (1.0 / 255.0)) {
        discard_fragment();
    }
    return float4(maskAlpha, maskAlpha, maskAlpha, maskAlpha);
}

fragment float4 volumeFragment(VSOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               texture3d<float> volumeTex [[texture(0)]],
                               texture3d<float> trackMatteTex [[texture(1)]],
                               sampler samp [[sampler(0)]]) {
    float3 cameraLocal = (u.invModelMatrix * float4(u.cameraPositionWorld, 1.0)).xyz;
    float3 surfaceLocal = in.localPos;
    float3 rayDir = normalize(surfaceLocal - cameraLocal);

    if (u.matteDiscardTransparent != 0u) {
        return renderAlphaMatte(cameraLocal, rayDir, u, volumeTex, samp);
    }

    float4 color;
    if (u.useVoxelBlockRendering != 0u) {
        color = renderVoxelBlocks(cameraLocal, rayDir, u, volumeTex, samp, in.position.xy);
    } else {
        color = renderContinuous(cameraLocal, rayDir, u, volumeTex, samp, in.position.xy);
    }

    if (u.trackMatteEnabled != 0u) {
        float3 rayDirWorld = normalize(in.worldPos - u.cameraPositionWorld);
        float3 matteCameraLocal = (u.trackMatteInvModelMatrix * float4(u.cameraPositionWorld, 1.0)).xyz;
        float3 matteRayDir = normalize((u.trackMatteInvModelMatrix * float4(rayDirWorld, 0.0)).xyz);
        float matteAlpha = sampleAlphaAlongRay(
            matteCameraLocal,
            matteRayDir,
            u.steps,
            u.trackMatteUseAlpha,
            u.trackMatteOpacity,
            trackMatteTex,
            samp
        );
        if (matteAlpha <= (1.0 / 255.0)) {
            discard_fragment();
        }
        color.rgb *= matteAlpha;
        color.a *= matteAlpha;
    }

    return color;
}

fragment float4 volumeArrayFragment(VSOut in [[stage_in]],
                                    constant Uniforms &u [[buffer(0)]],
                                    texture2d_array<float> volumeTex [[texture(0)]],
                                    texture2d_array<float> trackMatteTex [[texture(1)]],
                                    sampler samp [[sampler(0)]]) {
    float3 cameraLocal = (u.invModelMatrix * float4(u.cameraPositionWorld, 1.0)).xyz;
    float3 surfaceLocal = in.localPos;
    float3 rayDir = normalize(surfaceLocal - cameraLocal);

    if (u.matteDiscardTransparent != 0u) {
        return renderAlphaMatteArray(cameraLocal, rayDir, u, volumeTex, samp);
    }

    float4 color;
    if (u.useVoxelBlockRendering != 0u) {
        color = renderVoxelBlocksArray(cameraLocal, rayDir, u, volumeTex, samp, in.position.xy);
    } else {
        color = renderContinuousArray(cameraLocal, rayDir, u, volumeTex, samp, in.position.xy);
    }

    if (u.trackMatteEnabled != 0u) {
        float3 rayDirWorld = normalize(in.worldPos - u.cameraPositionWorld);
        float3 matteCameraLocal = (u.trackMatteInvModelMatrix * float4(u.cameraPositionWorld, 1.0)).xyz;
        float3 matteRayDir = normalize((u.trackMatteInvModelMatrix * float4(rayDirWorld, 0.0)).xyz);
        float matteAlpha = sampleAlphaAlongRayArray(
            matteCameraLocal,
            matteRayDir,
            u.steps,
            u.trackMatteUseAlpha,
            u.trackMatteOpacity,
            trackMatteTex,
            samp
        );
        if (matteAlpha <= (1.0 / 255.0)) {
            discard_fragment();
        }
        color.rgb *= matteAlpha;
        color.a *= matteAlpha;
    }

    return color;
}
