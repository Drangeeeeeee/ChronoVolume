#include <metal_stdlib>
using namespace metal;

struct PlaneSliceUniforms {
    uint outWidth;
    uint outHeight;
    uint useAlpha;
    uint showCheckerboard;
    uint fastPreview;
    uint volumeWidth;
    uint volumeHeight;
    uint volumeDepth;

    float contentX;
    float contentY;
    float contentW;
    float contentH;

    float3 u;
    float _pad1;
    float3 v;
    float _pad2;
    float3 n;
    float d;
    float uMin;
    float uMax;
    float vMin;
    float vMax;
};

kernel void planeSliceKernel(
    texture3d<float, access::sample> volumeTex [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    constant PlaneSliceUniforms& ubo [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float gx = float(gid.x);
    float gy = float(gid.y);

    // 固定最大画布：实际内容只占 contentRect，其余区域透明
    if (gx < ubo.contentX || gx >= ubo.contentX + ubo.contentW ||
        gy < ubo.contentY || gy >= ubo.contentY + ubo.contentH) {
        outTex.write(float4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    float px = (gx - ubo.contentX + 0.5f) / max(ubo.contentW, 1.0f);
    float py = (gy - ubo.contentY + 0.5f) / max(ubo.contentH, 1.0f);

    float fu = mix(ubo.uMin, ubo.uMax, px);
    float fv = mix(ubo.vMin, ubo.vMax, py);

    float3 centered = ubo.u * fu + ubo.v * fv + ubo.n * ubo.d;

    float3 dims = float3(float(ubo.volumeWidth), float(ubo.volumeHeight), float(ubo.volumeDepth));
    float3 voxel = centered + (dims - 1.0f) * 0.5f;

    if (voxel.x < 0.0f || voxel.x > dims.x - 1.0f ||
        voxel.y < 0.0f || voxel.y > dims.y - 1.0f ||
        voxel.z < 0.0f || voxel.z > dims.z - 1.0f) {
        outTex.write(float4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    float3 uvw = (voxel + 0.5f) / dims;
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

    float4 c = ubo.fastPreview ? volumeTex.sample(nearestSampler, uvw)
                               : volumeTex.sample(linearSampler, uvw);

    if (ubo.showCheckerboard != 0 && ubo.useAlpha != 0) {
        uint tile = 12;
        bool isDark = (((gid.x / tile) + (gid.y / tile)) % 2) == 0;
        float bg = isDark ? 0.70588235f : 0.92156863f;
        c.rgb = bg * (1.0f - c.a) + c.rgb * c.a;
        c.a = 1.0f;
    }

    outTex.write(c, gid);
}
