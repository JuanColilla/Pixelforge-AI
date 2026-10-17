// Lifts the foreground subjects of an image with Vision and writes them as a PNG whose alpha
// is the subject mask, at the source resolution.
//
// Usage: subject-mask [--device ane|gpu|cpu|auto] <input-image> <output.png>
// Exit codes: 0 success (one JSON line on stdout), 1 failure, 2 no subject found, 64 usage.

import CoreImage
import CoreML
import Foundation
import Vision

struct Failure: Error {
    let message: String
    let code: Int32
}

enum DevicePreference: String {
    case ane, gpu, cpu, auto
}

func parseArguments() throws -> (input: URL, output: URL, device: DevicePreference) {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var device = DevicePreference.ane
    if let flag = arguments.firstIndex(of: "--device") {
        guard flag + 1 < arguments.count, let value = DevicePreference(rawValue: arguments[flag + 1]) else {
            throw Failure(message: "--device must be ane, gpu, cpu or auto", code: 64)
        }
        device = value
        arguments.removeSubrange(flag...(flag + 1))
    }
    guard arguments.count == 2 else {
        throw Failure(message: "usage: subject-mask [--device ane|gpu|cpu|auto] <input-image> <output.png>", code: 64)
    }
    return (URL(fileURLWithPath: arguments[0]), URL(fileURLWithPath: arguments[1]), device)
}

/// Pins the request's main stage to the preferred device when Vision supports it there;
/// otherwise Vision keeps choosing. Returns the device the main stage is assigned to.
func assignDevice(_ preference: DevicePreference, to request: VNRequest) throws -> String {
    guard preference != .auto else { return "auto" }
    let supported = try request.supportedComputeStageDevices[.main] ?? []
    let match = supported.first { device in
        switch (preference, device) {
        case (.ane, .neuralEngine), (.gpu, .gpu), (.cpu, .cpu): true
        default: false
        }
    }
    guard let match else { return "auto" }
    request.setComputeDevice(match, for: .main)
    return preference.rawValue
}

func liftSubject(input: URL, output: URL, preference: DevicePreference) throws -> [String: Any] {
    let started = ContinuousClock.now
    let handler = VNImageRequestHandler(url: input)
    let request = VNGenerateForegroundInstanceMaskRequest()
    let device = try assignDevice(preference, to: request)
    try handler.perform([request])
    guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
        throw Failure(message: "no foreground subject found", code: 2)
    }
    let masked = try observation.generateMaskedImage(
        ofInstances: observation.allInstances,
        from: handler,
        croppedToInstancesExtent: false
    )
    let visionTime = ContinuousClock.now - started

    let image = CIImage(cvPixelBuffer: masked)
    guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw Failure(message: "sRGB color space unavailable", code: 1)
    }
    try CIContext().writePNGRepresentation(of: image, to: output, format: .RGBA8, colorSpace: sRGB)
    let totalTime = ContinuousClock.now - started

    return [
        "instances": observation.allInstances.count,
        "width": Int(image.extent.width),
        "height": Int(image.extent.height),
        "device": device,
        "vision_ms": milliseconds(visionTime),
        "total_ms": milliseconds(totalTime),
    ]
}

func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
}

do {
    let (input, output, device) = try parseArguments()
    let summary = try liftSubject(input: input, output: output, preference: device)
    let json = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
    print(String(decoding: json, as: UTF8.self))
} catch let failure as Failure {
    FileHandle.standardError.write(Data((failure.message + "\n").utf8))
    exit(failure.code)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
