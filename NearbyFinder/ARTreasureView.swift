//
//  ARTreasureView.swift
//  NearbyFinder
//

#if os(iOS)
import SwiftUI
import RealityKit
import ARKit
import simd

/// camera assistance が推定した相手（宝）の位置に、金の宝箱と光の柱を AR 描画する。
/// ARSession は NearbySessionManager が NI と共有しているものをそのまま表示する。
struct ARTreasureView: UIViewRepresentable {
    let arSession: ARSession
    let peerTransform: simd_float4x4?

    final class Coordinator {
        var anchor: AnchorEntity?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = arSession

        let anchor = AnchorEntity(world: matrix_identity_float4x4)
        anchor.isEnabled = false

        // 金の宝箱
        let chest = ModelEntity(
            mesh: .generateBox(size: [0.28, 0.18, 0.18], cornerRadius: 0.03),
            materials: [SimpleMaterial(color: UIColor(red: 0.95, green: 0.72, blue: 0.18, alpha: 1), isMetallic: true)]
        )
        let lid = ModelEntity(
            mesh: .generateBox(size: [0.30, 0.05, 0.20], cornerRadius: 0.02),
            materials: [SimpleMaterial(color: UIColor(red: 0.75, green: 0.52, blue: 0.10, alpha: 1), isMetallic: true)]
        )
        lid.position.y = 0.11

        // 遠くからでも見つけやすい光の柱
        var beamMaterial = UnlitMaterial(color: .systemYellow)
        beamMaterial.blending = .transparent(opacity: 0.35)
        let beam = ModelEntity(
            mesh: .generateCylinder(height: 2.0, radius: 0.05),
            materials: [beamMaterial]
        )
        beam.position.y = 1.1

        anchor.addChild(chest)
        anchor.addChild(lid)
        anchor.addChild(beam)
        view.scene.addAnchor(anchor)
        context.coordinator.anchor = anchor
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        guard let anchor = context.coordinator.anchor else { return }
        if let peerTransform {
            anchor.isEnabled = true
            // 位置だけ使う（相手端末の傾きまで反映すると宝箱が斜めになって見づらい）
            anchor.position = SIMD3<Float>(
                peerTransform.columns.3.x,
                peerTransform.columns.3.y,
                peerTransform.columns.3.z
            )
        } else {
            anchor.isEnabled = false
        }
    }
}
#endif
