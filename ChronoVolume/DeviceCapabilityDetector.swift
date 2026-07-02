import Foundation
import IOKit

enum DeviceCapabilityDetector {
    static func detect(appVersion: String) -> WorkerCapabilities {
        let machineName = Host.current().localizedName ?? "Unknown"
        let hostName = Host.current().name ?? "Unknown"
        let cpuCores = ProcessInfo.processInfo.processorCount
        let memoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024 / 1024)
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let modelIdentifier = sysctlString("hw.model") ?? "Unknown"
        let productName = ioRegistryProductName() ?? machineName
        let passiveCooling = inferPassiveCooling(productName: productName, modelIdentifier: modelIdentifier)

        // GPU 核心数：优先读取 system_profiler 的真实值；失败再回退为 0（未知），不做硬编码写死。
        let gpuCores = exactGPUCoreCount() ?? 0

        return WorkerCapabilities(
            machineName: machineName,
            hostName: hostName,
            cpuCores: cpuCores,
            gpuCores: gpuCores,
            memoryGB: memoryGB,
            passiveCooling: passiveCooling,
            osVersion: osVersion,
            appVersion: appVersion,
            supportsAlpha4444: true,
            supportsHighPrecisionXY: true
        )
    }

    private static func exactGPUCoreCount() -> Int? {
        guard let output = runCommand("/usr/sbin/system_profiler", ["SPDisplaysDataType"]) else {
            return nil
        }

        let patterns = [
            #"Total Number of Cores:\s*(\d+)"#,
            #"Number of Cores:\s*(\d+)"#,
            #"Cores:\s*(\d+)"#
        ]

        for pattern in patterns {
            if let raw = firstMatch(in: output, pattern: pattern), let value = Int(raw) {
                return value
            }
        }
        return nil
    }

    private static func inferPassiveCooling(productName: String, modelIdentifier: String) -> Bool {
        let merged = (productName + " " + modelIdentifier).lowercased()
        return merged.contains("macbookair") || merged.contains("macbook air")
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let groupIndex = match.numberOfRanges > 1 ? 1 : 0
        guard let resultRange = Range(match.range(at: groupIndex), in: text) else { return nil }
        return String(text[resultRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runCommand(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        return String(cString: buffer)
    }

    private static func ioRegistryProductName() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        for key in ["product-name", "model"] {
            if let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                if let s = cf as? String, !s.isEmpty { return s }
                if let d = cf as? Data,
                   let s = String(data: d, encoding: .utf8)?
                    .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines)),
                   !s.isEmpty {
                    return s
                }
            }
        }

        return nil
    }
}
