import ExampleSupport
import Metal
import SwiftUI

@main struct DemoApp: App {
    public var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    var body: some View {
        Text("Hello, world!")
            .padding()
            .task {
                do {
                    try await verify()
                    Example.pass()
                } catch {
                    print("Test failed: \(error)")
                    exit(1)
                }
            }
    }
}

private func verify() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw StringError("No Metal device available")
    }
    let library = try device.makeDefaultLibrary(bundle: #bundle)

    let functionName = "xtool_verify"
    guard let function = library.makeFunction(name: functionName) else {
        throw StringError("Metal library is missing \(functionName). Found: \(library.functionNames)")
    }
    let pipeline = try await device.makeComputePipelineState(function: function)

    let input = (0..<64).map { UInt32($0) }
    let expected = input.map { $0 * $0 + 0x5854 }
    let length = input.count * MemoryLayout<UInt32>.stride
    guard let inputBuffer = device.makeBuffer(bytes: input, length: length),
          let outputBuffer = device.makeBuffer(length: length),
          let queue = device.makeCommandQueue(),
          let commandBuffer = queue.makeCommandBuffer(),
          let encoder = commandBuffer.makeComputeCommandEncoder()
    else { throw StringError("Failed to set up Metal compute pass") }

    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(inputBuffer, offset: 0, index: 0)
    encoder.setBuffer(outputBuffer, offset: 0, index: 1)
    encoder.dispatchThreadgroups(
        MTLSize(width: 1, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: input.count, height: 1, depth: 1)
    )
    encoder.endEncoding()
    commandBuffer.commit()
    await commandBuffer.completed()

    if let error = commandBuffer.error {
        throw StringError("Metal command buffer failed: \(error)")
    }

    let output = Array(UnsafeBufferPointer(
        start: outputBuffer.contents().assumingMemoryBound(to: UInt32.self),
        count: input.count
    ))
    guard output == expected else {
        throw StringError("Metal kernel produced unexpected output: \(output)")
    }
}
