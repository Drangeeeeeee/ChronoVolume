#include <metal_stdlib>
using namespace metal;

struct HighPrecisionAssembleUniforms {
    uint batchStart;
    uint batchCount;
    uint frameIndex;
    uint sourceWidth;
    uint sourceHeight;
    uint useAlpha;
    uint preserveAlpha;
    uint checkerboard;
};

struct HighPrecisionPlaneRawUniforms {
    uint contentWidth;
    uint contentHeight;
    uint sourceWidth;
    uint sourceHeight;
    uint sourceDepth;
    uint rawDepth;
    uint rawFrameOffset;
    uint frameBytes;
    uint frameIndex;
    uint sliceCount;
    uint useAlpha;
    uint preserveAlpha;
    uint checkerboard;
    uint _pad0;
    uint _padUInt1;
    uint _padUInt2;
    float3 planeU;
    float uMin;
    float3 planeV;
    float vMin;
    float3 planeN;
    float dBase;
    float uMax;
    float vMax;
    float dStep;
    float _padFloat1;
};

static float4 composeForExport(float4 src, constant HighPrecisionAssembleUniforms &u, uint checkerX, uint checkerY) {
    if (u.preserveAlpha != 0u) {
        return float4(src.rgb, src.a);
    }

    if (u.useAlpha == 0u) {
        return float4(src.rgb, 1.0);
    }

    float alpha = clamp(src.a, 0.0, 1.0);
    if (u.checkerboard != 0u) {
        uint tile = 12u;
        bool isDark = (((checkerX / tile) + (checkerY / tile)) % 2u) == 0u;
        float bg = isDark ? (180.0 / 255.0) : (235.0 / 255.0);
        float3 rgb = float3(bg) * (1.0 - alpha) + src.rgb * alpha;
        return float4(rgb, 1.0);
    } else {
        return float4(src.rgb * alpha, 1.0);
    }
}

static float4 composePlaneForExport(float4 src, constant HighPrecisionPlaneRawUniforms &u, uint checkerX, uint checkerY) {
    if (u.preserveAlpha != 0u) {
        return float4(src.rgb, src.a);
    }

    if (u.useAlpha == 0u) {
        return float4(src.rgb, 1.0);
    }

    float alpha = clamp(src.a, 0.0, 1.0);
    if (u.checkerboard != 0u) {
        uint tile = 12u;
        bool isDark = (((checkerX / tile) + (checkerY / tile)) % 2u) == 0u;
        float bg = isDark ? (180.0 / 255.0) : (235.0 / 255.0);
        float3 rgb = float3(bg) * (1.0 - alpha) + src.rgb * alpha;
        return float4(rgb, 1.0);
    } else {
        return float4(src.rgb * alpha, 1.0);
    }
}

static float4 sampleRawBGRA(
    device const uchar *rawFrames,
    constant HighPrecisionPlaneRawUniforms &u,
    int x,
    int y,
    int t
) {
    x = clamp(x, 0, int(u.sourceWidth) - 1);
    y = clamp(y, 0, int(u.sourceHeight) - 1);
    t = clamp(t, 0, int(u.sourceDepth) - 1);
    int localT = clamp(t - int(u.rawFrameOffset), 0, int(u.rawDepth) - 1);
    ulong offset = ulong(localT) * ulong(u.frameBytes) + ulong(y * int(u.sourceWidth) + x) * 4ul;
    float b = float(rawFrames[offset]) / 255.0;
    float g = float(rawFrames[offset + 1ul]) / 255.0;
    float r = float(rawFrames[offset + 2ul]) / 255.0;
    float a = float(rawFrames[offset + 3ul]) / 255.0;
    return float4(r, g, b, a);
}

static float4 sampleRawLinearBGRA(
    device const uchar *rawFrames,
    constant HighPrecisionPlaneRawUniforms &u,
    float x,
    float y,
    float t
) {
    if (x < 0.0 || y < 0.0 || t < 0.0 ||
        x > float(u.sourceWidth - 1u) ||
        y > float(u.sourceHeight - 1u) ||
        t > float(u.sourceDepth - 1u)) {
        return float4(0.0);
    }

    int x0 = int(floor(x));
    int y0 = int(floor(y));
    int t0 = int(floor(t));
    int x1 = min(x0 + 1, int(u.sourceWidth) - 1);
    int y1 = min(y0 + 1, int(u.sourceHeight) - 1);
    int t1 = min(t0 + 1, int(u.sourceDepth) - 1);
    float fx = x - float(x0);
    float fy = y - float(y0);
    float ft = t - float(t0);

    float4 c000 = sampleRawBGRA(rawFrames, u, x0, y0, t0);
    float4 c100 = sampleRawBGRA(rawFrames, u, x1, y0, t0);
    float4 c010 = sampleRawBGRA(rawFrames, u, x0, y1, t0);
    float4 c110 = sampleRawBGRA(rawFrames, u, x1, y1, t0);
    float4 c001 = sampleRawBGRA(rawFrames, u, x0, y0, t1);
    float4 c101 = sampleRawBGRA(rawFrames, u, x1, y0, t1);
    float4 c011 = sampleRawBGRA(rawFrames, u, x0, y1, t1);
    float4 c111 = sampleRawBGRA(rawFrames, u, x1, y1, t1);

    float4 c00 = mix(c000, c100, fx);
    float4 c10 = mix(c010, c110, fx);
    float4 c01 = mix(c001, c101, fx);
    float4 c11 = mix(c011, c111, fx);
    float4 c0 = mix(c00, c10, fy);
    float4 c1 = mix(c01, c11, fy);
    return mix(c0, c1, ft);
}

kernel void highPrecisionAssembleXKernel(
    texture2d<float, access::read> srcTex [[texture(0)]],
    texture2d_array<float, access::write> outTex [[texture(1)]],
    constant HighPrecisionAssembleUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint localSlice = gid.x;
    uint y = gid.y;

    if (localSlice >= u.batchCount || y >= u.sourceHeight) return;

    uint srcX = u.batchStart + localSlice;
    if (srcX >= u.sourceWidth) return;
    if (u.frameIndex >= outTex.get_width()) return;

    float4 src = srcTex.read(uint2(srcX, y));
    float4 outColor = composeForExport(src, u, u.frameIndex, y);
    outTex.write(outColor, uint2(u.frameIndex, y), localSlice);
}

kernel void highPrecisionAssembleYKernel(
    texture2d<float, access::read> srcTex [[texture(0)]],
    texture2d_array<float, access::write> outTex [[texture(1)]],
    constant HighPrecisionAssembleUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint localSlice = gid.x;
    uint x = gid.y;

    if (localSlice >= u.batchCount || x >= u.sourceWidth) return;

    uint srcY = u.batchStart + localSlice;
    if (srcY >= u.sourceHeight) return;
    if (u.frameIndex >= outTex.get_height()) return;

    float4 src = srcTex.read(uint2(x, srcY));
    float4 outColor = composeForExport(src, u, x, u.frameIndex);
    outTex.write(outColor, uint2(x, u.frameIndex), localSlice);
}

kernel void highPrecisionPlaneRawKernel(
    device const uchar *rawFrames [[buffer(0)]],
    texture2d<float, access::write> outTex [[texture(0)]],
    constant HighPrecisionPlaneRawUniforms &u [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;
    if (gid.x >= u.contentWidth || gid.y >= u.contentHeight) {
        outTex.write(float4(0.0), gid);
        return;
    }

    float fu = u.uMin + (float(gid.x) + 0.5) / float(max(u.contentWidth, 1u)) * (u.uMax - u.uMin);
    float fv = u.vMin + (float(gid.y) + 0.5) / float(max(u.contentHeight, 1u)) * (u.vMax - u.vMin);
    float d = u.dBase + float(u.frameIndex) * u.dStep;
    float3 centered = u.planeU * fu + u.planeV * fv + u.planeN * d;

    float x = centered.x + float(u.sourceWidth - 1u) * 0.5;
    float y = centered.y + float(u.sourceHeight - 1u) * 0.5;
    float t = centered.z + float(u.sourceDepth - 1u) * 0.5;
    float4 src = sampleRawLinearBGRA(rawFrames, u, x, y, t);
    float4 outColor = composePlaneForExport(src, u, gid.x, gid.y);
    outTex.write(outColor, gid);
}
