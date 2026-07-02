#include <metal_stdlib>
using namespace metal;

struct SliceUniformsGPU {
    uint mode;
    uint axis;
    uint currentIndex;
    uint flags;

    uint3 volumeSize;
    uint _pad0;

    uint2 outputSize;
    uint2 logicalSize;

    float3 planeU;
    float planeUMin;
    float3 planeV;
    float planeVMin;
    float3 planeN;
    float planeNMin;

    float planeUMax;
    float planeVMax;
    float planeNMax;
    float _pad1;
};

static inline bool hasFlag(uint flags, uint bit) {
    return (flags & (1u << bit)) != 0u;
}

static inline float2 fitRectUV(uint2 gid, uint2 outSize, uint2 logicalSize, thread bool &inside) {
    float outW = max(1.0, float(outSize.x));
    float outH = max(1.0, float(outSize.y));
    float logicalW = max(1.0, float(logicalSize.x));
    float logicalH = max(1.0, float(logicalSize.y));

    float outAspect = outW / outH;
    float sliceAspect = logicalW / logicalH;

    float2 displayOrigin;
    float2 displaySize;

    if (outAspect > sliceAspect) {
        displaySize = float2(outH * sliceAspect, outH);
        displayOrigin = float2((outW - displaySize.x) * 0.5, 0.0);
    } else {
        displaySize = float2(outW, outW / sliceAspect);
        displayOrigin = float2(0.0, (outH - displaySize.y) * 0.5);
    }

    float2 p = float2(gid) + 0.5;
    inside = (p.x >= displayOrigin.x && p.y >= displayOrigin.y && p.x < displayOrigin.x + displaySize.x && p.y < displayOrigin.y + displaySize.y);
    if (!inside) {
        return float2(0.0);
    }

    return (p - displayOrigin) / displaySize;
}

static inline float4 applyCheckerboard(float4 color, float2 uv, uint2 logicalSize, bool checkerboard, bool useAlpha) {
    if (!checkerboard) {
        return float4(color.rgb, 1.0);
    }

    float a = useAlpha ? color.a : 1.0;
    uint x = uint(clamp(uv.x * float(max(logicalSize.x, 1u)), 0.0, float(max(logicalSize.x, 1u) - 1u)));
    uint y = uint(clamp(uv.y * float(max(logicalSize.y, 1u)), 0.0, float(max(logicalSize.y, 1u) - 1u)));
    uint tile = 12u;
    bool dark = (((x / tile) + (y / tile)) & 1u) == 0u;
    float bg = dark ? 180.0 / 255.0 : 235.0 / 255.0;
    float3 rgb = mix(float3(bg), color.rgb, a);
    return float4(rgb, 1.0);
}

kernel void sliceKernel(texture3d<float, access::sample> volumeTex [[texture(0)]],
                        texture2d<half, access::write> outTex [[texture(1)]],
                        constant SliceUniformsGPU &u [[buffer(0)]],
                        sampler linearSampler [[sampler(0)]],
                        sampler nearestSampler [[sampler(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= u.outputSize.x || gid.y >= u.outputSize.y) {
        return;
    }

    bool inside = false;
    float2 uv = fitRectUV(gid, u.outputSize, u.logicalSize, inside);
    if (!inside) {
        outTex.write(half4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    const bool checkerboard = hasFlag(u.flags, 0);
    const bool useAlpha = hasFlag(u.flags, 1);
    const bool fastPreview = hasFlag(u.flags, 2);

    float4 color = float4(0.0);

    if (u.mode == 0u) {
        if (u.axis == 0u) {
            // T 轴：x/y 图像
            float x = uv.x * max(0.0, float(u.volumeSize.x) - 1.0);
            float y = uv.y * max(0.0, float(u.volumeSize.y) - 1.0);
            float z = clamp(float(u.currentIndex), 0.0, float(u.volumeSize.z - 1u));
            float3 uvw = float3((x + 0.5) / float(u.volumeSize.x),
                                (y + 0.5) / float(u.volumeSize.y),
                                (z + 0.5) / float(u.volumeSize.z));
            color = volumeTex.sample(nearestSampler, uvw);
        } else if (u.axis == 1u) {
            // X 轴：t/y 图像
            float t = uv.x * max(0.0, float(u.volumeSize.z) - 1.0);
            float y = uv.y * max(0.0, float(u.volumeSize.y) - 1.0);
            float x = clamp(float(u.currentIndex), 0.0, float(u.volumeSize.x - 1u));
            float3 uvw = float3((x + 0.5) / float(u.volumeSize.x),
                                (y + 0.5) / float(u.volumeSize.y),
                                (t + 0.5) / float(u.volumeSize.z));
            color = volumeTex.sample(nearestSampler, uvw);
        } else {
            // Y 轴：x/t 图像
            float x = uv.x * max(0.0, float(u.volumeSize.x) - 1.0);
            float t = uv.y * max(0.0, float(u.volumeSize.z) - 1.0);
            float y = clamp(float(u.currentIndex), 0.0, float(u.volumeSize.y - 1u));
            float3 uvw = float3((x + 0.5) / float(u.volumeSize.x),
                                (y + 0.5) / float(u.volumeSize.y),
                                (t + 0.5) / float(u.volumeSize.z));
            color = volumeTex.sample(nearestSampler, uvw);
        }
    } else {
        // 参考面
        float sliceCount = max(1.0, u.planeNMax - u.planeNMin);
        float d;
        if (sliceCount <= 1.0) {
            d = (u.planeNMin + u.planeNMax) * 0.5;
        } else {
            d = u.planeNMin + (u.planeNMax - u.planeNMin) * (float(u.currentIndex) / max(1.0, ceil(u.planeNMax - u.planeNMin) - 1.0));
        }

        float fu = mix(u.planeUMin, u.planeUMax, uv.x);
        float fv = mix(u.planeVMax, u.planeVMin, uv.y);
        float3 centered = u.planeU * fu + u.planeV * fv + u.planeN * d;

        float halfX = (float(u.volumeSize.x) - 1.0) * 0.5;
        float halfY = (float(u.volumeSize.y) - 1.0) * 0.5;
        float halfZ = (float(u.volumeSize.z) - 1.0) * 0.5;

        float x = centered.x + halfX;
        float y = centered.y + halfY;
        float z = centered.z + halfZ;

        if (x < 0.0 || y < 0.0 || z < 0.0 ||
            x > float(u.volumeSize.x - 1u) ||
            y > float(u.volumeSize.y - 1u) ||
            z > float(u.volumeSize.z - 1u)) {
            color = float4(0.0);
        } else {
            float3 uvw = float3((x + 0.5) / float(u.volumeSize.x),
                                (y + 0.5) / float(u.volumeSize.y),
                                (z + 0.5) / float(u.volumeSize.z));
            color = fastPreview ? volumeTex.sample(nearestSampler, uvw)
                                : volumeTex.sample(linearSampler, uvw);
        }
    }

    float4 outColor = applyCheckerboard(color, uv, u.logicalSize, checkerboard, useAlpha);
    outTex.write(half4(outColor), gid);
}
