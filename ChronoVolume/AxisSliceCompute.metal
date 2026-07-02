#include <metal_stdlib>
using namespace metal;

struct AxisSliceUniforms {
    uint outWidth;
    uint outHeight;
    uint useAlpha;
    uint showCheckerboard;
    uint fastPreview;
    uint axisType;
    uint fixedIndex;
    uint _pad0;

    uint volumeWidth;
    uint volumeHeight;
    uint volumeDepth;
    uint _pad1;

    float contentX;
    float contentY;
    float contentW;
    float contentH;
};

kernel void axisSliceKernel(
    texture3d<float, access::sample> volumeTex [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    constant AxisSliceUniforms& ubo [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) return;

    float gx = float(gid.x);
    float gy = float(gid.y);

    if (gx < ubo.contentX || gx >= ubo.contentX + ubo.contentW ||
        gy < ubo.contentY || gy >= ubo.contentY + ubo.contentH) {
        outTex.write(float4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    float px = (gx - ubo.contentX + 0.5f) / max(ubo.contentW, 1.0f);
    float py = (gy - ubo.contentY + 0.5f) / max(ubo.contentH, 1.0f);

    float3 dims = float3(float(ubo.volumeWidth), float(ubo.volumeHeight), float(ubo.volumeDepth));
    float3 voxel;

    if (ubo.axisType == 0) {
        // X 轴作时间轴：横向是 T，纵向是 Y
        voxel.x = float(ubo.fixedIndex);
        voxel.y = py * (dims.y - 1.0f);
        voxel.z = px * (dims.z - 1.0f);
    } else if (ubo.axisType == 1) {
        // Y 轴作时间轴：横向是 X，纵向是 T
        voxel.x = px * (dims.x - 1.0f);
        voxel.y = float(ubo.fixedIndex);
        voxel.z = py * (dims.z - 1.0f);
    } else {
        // T 轴：横向是 X，纵向是 Y
        voxel.x = px * (dims.x - 1.0f);
        voxel.y = py * (dims.y - 1.0f);
        voxel.z = float(ubo.fixedIndex);
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
