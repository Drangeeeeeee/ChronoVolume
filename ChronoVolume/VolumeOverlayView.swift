import SwiftUI
import simd

struct VolumeOverlayView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                guard model.volumeInfo != "-" else { return }

                if model.showCornerAxesOverlay {
                    drawCornerAxes(context: &context)
                }

        if model.showOriginAxesOverlay || model.showCameraOverlay {
            drawProjectedScene(context: &context, size: size)
        }
            }
        }
        .allowsHitTesting(false)
    }

    private func correctedBasis() -> (u: SIMD3<Float>, v: SIMD3<Float>, n: SIMD3<Float>) {
        model.correctedPlaneBasis()
    }

    private func drawCornerAxes(context: inout GraphicsContext) {
        let rotY = ovRotation3x3(angle: model.cameraYaw, axis: SIMD3<Float>(0, 1, 0))
        let rotX = ovRotation3x3(angle: model.cameraPitch, axis: SIMD3<Float>(1, 0, 0))
        let rotZ = ovRotation3x3(angle: model.cameraRoll, axis: SIMD3<Float>(0, 0, 1))
        let rot = rotY * rotX * rotZ

        let origin = CGPoint(x: 72, y: 72)
        let axisLen: CGFloat = 42

        func project2D(_ v: SIMD3<Float>) -> CGPoint {
            let rv = rot * v
            return CGPoint(
                x: origin.x + CGFloat(rv.x) * axisLen,
                y: origin.y - CGFloat(rv.y) * axisLen
            )
        }

        drawAxis2D(
            context: &context,
            from: origin,
            to: project2D(SIMD3<Float>(1, 0, 0)),
            color: .red,
            label: "X"
        )

        drawAxis2D(
            context: &context,
            from: origin,
            to: project2D(SIMD3<Float>(0, 1, 0)),
            color: .green,
            label: "Y"
        )

        drawAxis2D(
            context: &context,
            from: origin,
            to: project2D(SIMD3<Float>(0, 0, -1)),
            color: .cyan,
            label: "T"
        )
    }

    private func drawProjectedScene(context: inout GraphicsContext, size: CGSize) {
        let aspect = Float(max(0.1, size.width / max(1.0, size.height)))
        let proj = ovPerspectiveFovRH(
            fovyRadians: ovRadians(50),
            aspect: aspect,
            nearZ: 0.1,
            farZ: 100
        )
        let viewMat = ovTranslationMatrix(SIMD3<Float>(0, 0, -model.cameraDistance))
        let orbitRotation = ovRotationMatrix(angle: model.cameraYaw, axis: SIMD3<Float>(0, 1, 0))
            * ovRotationMatrix(angle: model.cameraPitch, axis: SIMD3<Float>(1, 0, 0))
        let sceneMVP = proj * viewMat * orbitRotation

        func projectScene(_ p: SIMD3<Float>) -> CGPoint? {
            let clip = sceneMVP * SIMD4<Float>(p.x, p.y, p.z, 1)
            if clip.w <= 0.0001 { return nil }

            let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
            let sx = (CGFloat(ndc.x) * 0.5 + 0.5) * size.width
            let sy = (1.0 - (CGFloat(ndc.y) * 0.5 + 0.5)) * size.height
            return CGPoint(x: sx, y: sy)
        }

        if model.showOriginAxesOverlay {
            drawProjectedAxis(
                context: &context,
                project: projectScene,
                from: SIMD3<Float>(0, 0, 0),
                to: SIMD3<Float>(0.65, 0, 0),
                color: .red,
                label: "X"
            )

            drawProjectedAxis(
                context: &context,
                project: projectScene,
                from: SIMD3<Float>(0, 0, 0),
                to: SIMD3<Float>(0, 0.65, 0),
                color: .green,
                label: "Y"
            )

            drawProjectedAxis(
                context: &context,
                project: projectScene,
                from: SIMD3<Float>(0, 0, 0),
                to: SIMD3<Float>(0, 0, -0.65),
                color: .cyan,
                label: "T"
            )
        }

        if model.showCameraOverlay {
            drawProjectedCamera(context: &context, project: projectScene)
        }
    }

    private func drawAxis2D(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        color: Color,
        label: String
    ) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(color), lineWidth: 2.5)

        context.draw(
            Text(label).font(.system(size: 12, weight: .bold)).foregroundColor(color),
            at: CGPoint(x: to.x + 10, y: to.y - 10)
        )
    }

    private func drawProjectedAxis(
        context: inout GraphicsContext,
        project: (SIMD3<Float>) -> CGPoint?,
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        color: Color,
        label: String
    ) {
        guard let p0 = project(from), let p1 = project(to) else { return }

        var path = Path()
        path.move(to: p0)
        path.addLine(to: p1)
        context.stroke(path, with: .color(color), lineWidth: 2.5)

        context.draw(
            Text(label).font(.system(size: 12, weight: .bold)).foregroundColor(color),
            at: CGPoint(x: p1.x + 10, y: p1.y - 10)
        )
    }

    private func drawProjectedArrow(
        context: inout GraphicsContext,
        project: (SIMD3<Float>) -> CGPoint?,
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        color: Color,
        label: String
    ) {
        guard let p0 = project(from), let p1 = project(to) else { return }

        var path = Path()
        path.move(to: p0)
        path.addLine(to: p1)
        context.stroke(path, with: .color(color), lineWidth: 2.0)

        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        let len = max(1.0, sqrt(dx * dx + dy * dy))
        let ux = dx / len
        let uy = dy / len

        let head: CGFloat = 10
        let wing: CGFloat = 5

        let left = CGPoint(
            x: p1.x - ux * head - uy * wing,
            y: p1.y - uy * head + ux * wing
        )
        let right = CGPoint(
            x: p1.x - ux * head + uy * wing,
            y: p1.y - uy * head - ux * wing
        )

        var headPath = Path()
        headPath.move(to: p1)
        headPath.addLine(to: left)
        headPath.move(to: p1)
        headPath.addLine(to: right)
        context.stroke(headPath, with: .color(color), lineWidth: 2.0)

        context.draw(
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(color),
            at: CGPoint(x: p1.x + 14, y: p1.y - 12)
        )
    }

    private func drawProjectedCamera(
        context: inout GraphicsContext,
        project: (SIMD3<Float>) -> CGPoint?
    ) {
        let cameraPosition = SIMD3<Float>(model.cameraRig.positionX, model.cameraRig.positionY, model.cameraRig.positionZ)
        let cameraWorld = model.cameraRig.focusLockEnabled
            ? ovLookAtCameraWorldMatrix(
                position: cameraPosition,
                target: SIMD3<Float>(model.cameraRig.focusTargetX, model.cameraRig.focusTargetY, model.cameraRig.focusTargetZ),
                roll: model.cameraRig.roll
            )
            : ovCameraWorldMatrix(
                yaw: model.cameraRig.yaw,
                pitch: model.cameraRig.pitch,
                roll: model.cameraRig.roll,
                distance: 0,
                position: cameraPosition
            )

        let origin4 = cameraWorld * SIMD4<Float>(0, 0, 0, 1)
        let origin = SIMD3<Float>(origin4.x, origin4.y, origin4.z)
        guard let projectedOrigin = project(origin) else { return }

        let localScale: Float = 0.12
        let forward = ovTransformPoint(cameraWorld, SIMD3<Float>(0, 0, -localScale * 1.8))
        let up = ovTransformPoint(cameraWorld, SIMD3<Float>(0, localScale, 0))
        let right = ovTransformPoint(cameraWorld, SIMD3<Float>(localScale, 0, 0))
        let left = ovTransformPoint(cameraWorld, SIMD3<Float>(-localScale, 0, 0))

        if let pf = project(forward),
           let pu = project(up),
           let pr = project(right),
           let pl = project(left) {
            var body = Path()
            body.move(to: projectedOrigin)
            body.addLine(to: pr)
            body.addLine(to: pf)
            body.addLine(to: pl)
            body.closeSubpath()
            context.fill(body, with: .color(Color.orange.opacity(0.22)))
            context.stroke(body, with: .color(Color.orange.opacity(0.95)), lineWidth: 2.0)

            var upPath = Path()
            upPath.move(to: projectedOrigin)
            upPath.addLine(to: pu)
            context.stroke(upPath, with: .color(.white.opacity(0.8)), lineWidth: 1.5)

            var forwardPath = Path()
            forwardPath.move(to: projectedOrigin)
            forwardPath.addLine(to: pf)
            context.stroke(forwardPath, with: .color(.orange), lineWidth: 2.0)

            context.fill(
                Path(ellipseIn: CGRect(x: projectedOrigin.x - 4, y: projectedOrigin.y - 4, width: 8, height: 8)),
                with: .color(.orange)
            )
            context.draw(
                Text("Cam").font(.system(size: 11, weight: .bold)).foregroundColor(.orange),
                at: CGPoint(x: projectedOrigin.x + 18, y: projectedOrigin.y - 14)
            )
        }
    }
}

private func ovRadians(_ degrees: Float) -> Float {
    degrees * .pi / 180.0
}

private func ovPerspectiveFovRH(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
    let yScale = 1.0 / tan(fovyRadians * 0.5)
    let xScale = yScale / aspect
    let zRange = farZ - nearZ
    let zScale = -(farZ + nearZ) / zRange
    let wzScale = -2.0 * farZ * nearZ / zRange

    return simd_float4x4(
        SIMD4<Float>( xScale, 0,      0,       0),
        SIMD4<Float>( 0,      yScale, 0,       0),
        SIMD4<Float>( 0,      0,      zScale, -1),
        SIMD4<Float>( 0,      0,      wzScale, 0)
    )
}

private func ovTranslationMatrix(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(t.x, t.y, t.z, 1)
    )
}

private func ovScaleMatrix(_ s: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(
        SIMD4<Float>(s.x, 0,   0,   0),
        SIMD4<Float>(0,   s.y, 0,   0),
        SIMD4<Float>(0,   0,   s.z, 0),
        SIMD4<Float>(0,   0,   0,   1)
    )
}

private func ovVolumeTransformMatrix(_ transform: VolumeTransformState) -> simd_float4x4 {
    let translation = ovTranslationMatrix(
        SIMD3<Float>(transform.positionX, transform.positionY, transform.positionZ)
    )
    let rotX = ovRotationMatrix(angle: transform.rotationX, axis: SIMD3<Float>(1, 0, 0))
    let rotY = ovRotationMatrix(angle: transform.rotationY, axis: SIMD3<Float>(0, 1, 0))
    let rotZ = ovRotationMatrix(angle: transform.rotationZ, axis: SIMD3<Float>(0, 0, 1))
    let scale = SIMD3<Float>(
        max(0.01, transform.scaleX),
        max(0.01, transform.scaleY),
        max(0.01, transform.scaleZ)
    )
    return translation * rotZ * rotY * rotX * ovScaleMatrix(scale)
}

private func ovRotationMatrix(angle: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    let a = simd_normalize(axis)
    let x = a.x
    let y = a.y
    let z = a.z
    let c = cos(angle)
    let s = sin(angle)
    let mc = 1 - c

    return simd_float4x4(
        SIMD4<Float>(c + x*x*mc,     x*y*mc + z*s,   x*z*mc - y*s,   0),
        SIMD4<Float>(x*y*mc - z*s,   c + y*y*mc,     y*z*mc + x*s,   0),
        SIMD4<Float>(x*z*mc + y*s,   y*z*mc - x*s,   c + z*z*mc,     0),
        SIMD4<Float>(0,              0,              0,              1)
    )
}

private func ovRotation3x3(angle: Float, axis: SIMD3<Float>) -> simd_float3x3 {
    let a = simd_normalize(axis)
    let x = a.x
    let y = a.y
    let z = a.z
    let c = cos(angle)
    let s = sin(angle)
    let mc = 1 - c

    return simd_float3x3(
        SIMD3<Float>(c + x*x*mc,     x*y*mc + z*s,   x*z*mc - y*s),
        SIMD3<Float>(x*y*mc - z*s,   c + y*y*mc,     y*z*mc + x*s),
        SIMD3<Float>(x*z*mc + y*s,   y*z*mc - x*s,   c + z*z*mc)
    )
}

private func ovCameraWorldMatrix(
    yaw: Float,
    pitch: Float,
    roll: Float,
    distance: Float,
    position: SIMD3<Float>
) -> simd_float4x4 {
    let rotY = ovRotationMatrix(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
    let rotX = ovRotationMatrix(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
    let rotZ = ovRotationMatrix(angle: roll, axis: SIMD3<Float>(0, 0, 1))
    return ovTranslationMatrix(position + SIMD3<Float>(0, 0, distance)) * rotY * rotX * rotZ
}

private func ovLookAtCameraWorldMatrix(position: SIMD3<Float>, target: SIMD3<Float>, roll: Float) -> simd_float4x4 {
    let toTarget = target - position
    let fallbackForward = SIMD3<Float>(0, 0, -1)
    let forward = simd_length_squared(toTarget) > 0.000001 ? simd_normalize(toTarget) : fallbackForward
    let worldUp = abs(simd_dot(forward, SIMD3<Float>(0, 1, 0))) > 0.98
        ? SIMD3<Float>(1, 0, 0)
        : SIMD3<Float>(0, 1, 0)

    var right = simd_normalize(simd_cross(forward, worldUp))
    var up = simd_normalize(simd_cross(right, forward))

    if abs(roll) > 0.000001 {
        let rollMat = ovRotationMatrix(angle: roll, axis: forward)
        right = ovTransformVector(rollMat, right)
        up = ovTransformVector(rollMat, up)
    }

    return simd_float4x4(
        SIMD4<Float>(right.x, right.y, right.z, 0),
        SIMD4<Float>(up.x, up.y, up.z, 0),
        SIMD4<Float>(-forward.x, -forward.y, -forward.z, 0),
        SIMD4<Float>(position.x, position.y, position.z, 1)
    )
}

private func ovTransformVector(_ matrix: simd_float4x4, _ vector: SIMD3<Float>) -> SIMD3<Float> {
    let v = matrix * SIMD4<Float>(vector.x, vector.y, vector.z, 0)
    return SIMD3<Float>(v.x, v.y, v.z)
}

private func ovTransformPoint(_ matrix: simd_float4x4, _ point: SIMD3<Float>) -> SIMD3<Float> {
    let p = matrix * SIMD4<Float>(point.x, point.y, point.z, 1)
    return SIMD3<Float>(p.x, p.y, p.z)
}
