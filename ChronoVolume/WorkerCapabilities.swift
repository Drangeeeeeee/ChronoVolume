import Foundation

struct WorkerCapabilities: Codable {
    let machineName: String
    let hostName: String
    let cpuCores: Int
    let gpuCores: Int
    let memoryGB: Int
    let passiveCooling: Bool

    let osVersion: String
    let appVersion: String

    let supportsAlpha4444: Bool
    let supportsHighPrecisionXY: Bool
}
