import simd

func radians(_ deg: Float) -> Float { deg * .pi / 180 }

func perspectiveFovRH(fovyRadians fovy: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
    let ys = 1 / tan(fovy * 0.5)
    let xs = ys / aspect
    let zs = farZ / (nearZ - farZ)
    return simd_float4x4(
        SIMD4<Float>( xs,  0,  0,   0),
        SIMD4<Float>(  0, ys,  0,   0),
        SIMD4<Float>(  0,  0, zs, -1),
        SIMD4<Float>(  0,  0, nearZ * zs, 0)
    )
}

func rotationMatrix(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    let a = normalize(axis)
    let x = a.x, y = a.y, z = a.z
    let c = cos(angle)
    let s = sin(angle)
    let mc = 1 - c

    return simd_float4x4(
        SIMD4<Float>(c + mc*x*x,     mc*x*y + z*s, mc*x*z - y*s, 0),
        SIMD4<Float>(mc*x*y - z*s, c + mc*y*y,     mc*y*z + x*s, 0),
        SIMD4<Float>(mc*x*z + y*s, mc*y*z - x*s, c + mc*z*z,     0),
        SIMD4<Float>(0, 0, 0, 1)
    )
}

func translationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(1,0,0,0),
        SIMD4<Float>(0,1,0,0),
        SIMD4<Float>(0,0,1,0),
        SIMD4<Float>(t.x,t.y,t.z,1)
    )
}

func scaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(s.x,0,0,0),
        SIMD4<Float>(0,s.y,0,0),
        SIMD4<Float>(0,0,s.z,0),
        SIMD4<Float>(0,0,0,1)
    )
}
