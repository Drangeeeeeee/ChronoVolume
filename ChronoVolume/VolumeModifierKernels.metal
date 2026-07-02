#include <metal_stdlib>
using namespace metal;

struct VolumeModifierUniforms {
    uint width;
    uint height;
    uint depth;
    uint modifierCount;
    float4 volumeScaleAndOutset; // xyz = displayed volume scale, w = virtual transparent boundary scale
    float4 outsetCenter;
};

struct VolumeModifierItem {
    float4x4 inverseAffine;
    float4 shape; // inflate, twistY, taperX, taperZ
    float4 inflateCenter;
};

static inline float3 transformPoint(float3 p, float4x4 matrix) {
    float4 v = matrix * float4(p, 1.0f);
    return v.xyz;
}

static inline float3 inverseShape(float3 p, float4 shape, float3 inflateCenter, float3 volumeScale) {
    const float inflate = shape.x;
    const float twistY = shape.y;
    const float taperX = shape.z;
    const float taperZ = shape.w;

    if (fabs(inflate) > 0.000001f) {
        float3 safeScale = max(volumeScale, float3(0.0001f));
        float3 scaledPoint = (p - inflateCenter) * safeScale;
        float len = length(scaledPoint);
        if (len > 0.000001f) {
            scaledPoint -= (scaledPoint / len) * inflate;
            p = inflateCenter + scaledPoint / safeScale;
        }
    }

    float vertical = clamp(p.y * 2.0f, -1.0f, 1.0f);

    if (fabs(twistY) > 0.000001f) {
        float angle = -twistY * vertical;
        float c = cos(angle);
        float s = sin(angle);
        float x = p.x * c - p.z * s;
        float z = p.x * s + p.z * c;
        p.x = x;
        p.z = z;
    }

    if (fabs(taperX) > 0.000001f) {
        p.x /= max(0.0001f, 1.0f + taperX * vertical);
    }
    if (fabs(taperZ) > 0.000001f) {
        p.z /= max(0.0001f, 1.0f + taperZ * vertical);
    }

    return p;
}

kernel void volumeModifierKernel(
    texture3d<float, access::sample> sourceTexture [[texture(0)]],
    texture3d<float, access::write> outputTexture [[texture(1)]],
    constant VolumeModifierUniforms& uniforms [[buffer(0)]],
    device const VolumeModifierItem *modifiers [[buffer(1)]],
    uint3 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms.width || gid.y >= uniforms.height || gid.z >= uniforms.depth) {
        return;
    }

    float3 dims = float3(
        float(max(uniforms.width, 1u)),
        float(max(uniforms.height, 1u)),
        float(max(uniforms.depth, 1u))
    );
    float3 denom = max(dims - 1.0f, float3(1.0f));

    float3 volumeScale = max(uniforms.volumeScaleAndOutset.xyz, float3(0.0001f));
    float outsetScale = max(uniforms.volumeScaleAndOutset.w, 1.0f);
    float3 normalizedPoint = float3(float(gid.x), float(gid.y), float(gid.z)) / denom - 0.5f;
    float3 outsetCenter = uniforms.outsetCenter.xyz;
    float3 p = outsetCenter + (normalizedPoint - outsetCenter) * outsetScale;

    uint count = min(uniforms.modifierCount, 32u);
    for (uint i = 0; i < count; ++i) {
        uint modifierIndex = count - 1u - i;
        VolumeModifierItem item = modifiers[modifierIndex];
        p = transformPoint(p, item.inverseAffine);
        p = inverseShape(p, item.shape, item.inflateCenter.xyz, volumeScale);
    }

    float3 voxel = (p + 0.5f) * denom;
    if (voxel.x < 0.0f || voxel.x > denom.x ||
        voxel.y < 0.0f || voxel.y > denom.y ||
        voxel.z < 0.0f || voxel.z > denom.z) {
        outputTexture.write(float4(0.0f), gid);
        return;
    }

    constexpr sampler linearSampler(coord::normalized, address::clamp_to_zero, filter::linear);
    float3 uvw = (voxel + 0.5f) / dims;
    float4 color = sourceTexture.sample(linearSampler, uvw);
    outputTexture.write(color, gid);
}
