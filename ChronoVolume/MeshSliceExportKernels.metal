#include <metal_stdlib>
using namespace metal;

struct MeshExportTriangleGPU {
    float3 a;
    float3 b;
    float3 c;
    float3 normal;
};

struct MeshSliceGPUUniforms {
    uint triangleCount;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    float3 planeN;
    float d;
    float3 planeU;
    float _padFloat0;
    float3 planeV;
    float _padFloat1;
    float3 lightDirection;
    float epsilon;
};

struct MeshSliceGPUOutput {
    float u0;
    float v0;
    float u1;
    float v1;
    float shade;
    uint active;
    uint _pad0;
    uint _pad1;
};

static void appendUniquePoint(thread float3 *points, thread uint &count, float3 point) {
    for (uint i = 0; i < count; i++) {
        float3 delta = points[i] - point;
        if (dot(delta, delta) < 0.000001) {
            return;
        }
    }

    if (count < 6u) {
        points[count] = point;
        count += 1u;
    }
}

static bool trianglePlaneIntersectionGPU(
    MeshExportTriangleGPU triangle,
    float3 normal,
    float d,
    float epsilon,
    thread float3 &out0,
    thread float3 &out1
) {
    float3 points[3] = { triangle.a, triangle.b, triangle.c };
    float distances[3] = {
        dot(points[0], normal) - d,
        dot(points[1], normal) - d,
        dot(points[2], normal) - d
    };

    if ((distances[0] > epsilon && distances[1] > epsilon && distances[2] > epsilon) ||
        (distances[0] < -epsilon && distances[1] < -epsilon && distances[2] < -epsilon)) {
        return false;
    }

    float3 intersections[6];
    uint intersectionCount = 0u;

    for (uint edge = 0u; edge < 3u; edge++) {
        uint next = (edge + 1u) % 3u;
        float3 p0 = points[edge];
        float3 p1 = points[next];
        float d0 = distances[edge];
        float d1 = distances[next];
        float ad0 = abs(d0);
        float ad1 = abs(d1);

        if (ad0 <= epsilon && ad1 <= epsilon) {
            appendUniquePoint(intersections, intersectionCount, p0);
            appendUniquePoint(intersections, intersectionCount, p1);
        } else if (ad0 <= epsilon) {
            appendUniquePoint(intersections, intersectionCount, p0);
        } else if (ad1 <= epsilon) {
            appendUniquePoint(intersections, intersectionCount, p1);
        } else if (d0 * d1 < 0.0) {
            float t = d0 / (d0 - d1);
            appendUniquePoint(intersections, intersectionCount, p0 + (p1 - p0) * t);
        }
    }

    if (intersectionCount < 2u) {
        return false;
    }

    uint bestI = 0u;
    uint bestJ = 1u;
    float3 bestDelta = intersections[1] - intersections[0];
    float bestDistance = dot(bestDelta, bestDelta);

    for (uint i = 0u; i < intersectionCount; i++) {
        for (uint j = i + 1u; j < intersectionCount; j++) {
            float3 delta = intersections[j] - intersections[i];
            float distance = dot(delta, delta);
            if (distance > bestDistance) {
                bestDistance = distance;
                bestI = i;
                bestJ = j;
            }
        }
    }

    if (bestDistance <= 0.000001) {
        return false;
    }

    out0 = intersections[bestI];
    out1 = intersections[bestJ];
    return true;
}

kernel void meshSliceIntersectKernel(
    device const MeshExportTriangleGPU *triangles [[buffer(0)]],
    device MeshSliceGPUOutput *outputs [[buffer(1)]],
    constant MeshSliceGPUUniforms &uniforms [[buffer(2)]],
    device const float2 *planeRanges [[buffer(3)]],
    device atomic_uint *outputCount [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= uniforms.triangleCount) {
        return;
    }

    float2 range = planeRanges[gid];
    if (uniforms.d < range.x - uniforms.epsilon ||
        uniforms.d > range.y + uniforms.epsilon) {
        return;
    }

    MeshExportTriangleGPU triangle = triangles[gid];
    float3 p0;
    float3 p1;
    if (!trianglePlaneIntersectionGPU(
        triangle,
        normalize(uniforms.planeN),
        uniforms.d,
        uniforms.epsilon,
        p0,
        p1
    )) {
        return;
    }

    float u0 = dot(p0, uniforms.planeU);
    float v0 = dot(p0, uniforms.planeV);
    float u1 = dot(p1, uniforms.planeU);
    float v1 = dot(p1, uniforms.planeV);
    if (abs(u1 - u0) + abs(v1 - v0) <= 0.0001) {
        return;
    }

    float shade = clamp(0.72 + 0.28 * abs(dot(normalize(triangle.normal), normalize(uniforms.lightDirection))), 0.68, 1.0);
    uint outputIndex = atomic_fetch_add_explicit(outputCount, 1u, memory_order_relaxed);
    if (outputIndex >= uniforms.triangleCount) {
        return;
    }

    outputs[outputIndex].u0 = u0;
    outputs[outputIndex].v0 = v0;
    outputs[outputIndex].u1 = u1;
    outputs[outputIndex].v1 = v1;
    outputs[outputIndex].shade = shade;
    outputs[outputIndex].active = 1u;
}
