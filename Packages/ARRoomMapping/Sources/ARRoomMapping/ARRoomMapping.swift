import Foundation
import simd

#if canImport(ARKit)
import ARKit
#endif
#if canImport(RealityKit)
import RealityKit
#endif

public struct PlaneAnchorInfo: Sendable, Equatable {
    public var normal: SIMD3<Float>
    public var center: SIMD3<Float>
    public var extent: SIMD2<Float>
    public init(normal: SIMD3<Float>, center: SIMD3<Float>, extent: SIMD2<Float>) {
        self.normal = normal
        self.center = center
        self.extent = extent
    }
}

public struct MeshInfo: Sendable, Equatable {
    public var vertices: [SIMD3<Float>]
    public var indices: [UInt32]
    public init(vertices: [SIMD3<Float>], indices: [UInt32]) {
        self.vertices = vertices
        self.indices = indices
    }
}

public enum SessionMode: Sendable, Equatable {
    case planes
    case mesh
    case roomplan
}

public protocol ARRoomMappingDelegate: AnyObject {
    func didUpdate(planes: [PlaneAnchorInfo])
    func didUpdate(mesh: MeshInfo)
}

public final class ARRoomMapper: @unchecked Sendable {
    public weak var delegate: ARRoomMappingDelegate?
    public init() {}

    public func start(mode: SessionMode) {
        // Stub: platform-specific session setup will be implemented later.
    }

    public func stop() {
        // Stub: stop AR session.
    }
}
