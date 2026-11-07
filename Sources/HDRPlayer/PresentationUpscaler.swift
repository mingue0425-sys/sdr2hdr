import CoreGraphics
import Foundation
import Metal
import MetalFX

/// How far the player upscales the processed HDR frame before presentation.
public enum HDRUpscaleMode: String, CaseIterable, Sendable {
    case off
    case x1_5 = "1.5x"
    case x2 = "2x"
    /// Up to the size the video occupies on screen.
    case auto

    public var displayName: String {
        switch self {
        case .off: return "끔 (쌍선형 보간)"
        case .x1_5: return "1.5×"
        case .x2: return "2×"
        case .auto: return "자동 (화면 크기까지)"
        }
    }

    public init?(cliName: String) {
        self.init(rawValue: cliName.lowercased())
    }

    /// The output size for an input of `input` pixels shown in `target`
    /// pixels on screen, or nil when upscaling would not add pixels. Factors
    /// never exceed the on-screen size; sizes are even.
    func outputSize(input: CGSize, target: CGSize) -> CGSize? {
        guard input.width >= 2, input.height >= 2, target.width > 0, target.height > 0 else { return nil }
        let factor: CGFloat
        switch self {
        case .off: return nil
        case .x1_5: factor = 1.5
        case .x2: factor = 2
        case .auto: factor = min(target.width / input.width, target.height / input.height)
        }
        let capped = min(factor, target.width / input.width, target.height / input.height)
        // Below 5% more pixels per axis the scaler cannot add detail.
        guard capped >= 1.05 else { return nil }
        // Quantised, so live window resizing does not rebuild the scaler every frame.
        let step: CGFloat = self == .auto ? 32 : 2
        let width = max(2, (input.width * capped / step).rounded(.down) * step)
        let height = max(2, (input.height * capped / step).rounded(.down) * step)
        guard width > input.width, height > input.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

/// MetalFX spatial upscaling of the processed EDR frame.
///
/// The frame is linear light with values above 1 (EDR), so the scaler runs in
/// its HDR colour mode, which tone-maps reversibly around the upscale. The
/// presentation shader then maps the larger texture exactly as before, so EDR
/// headroom handling, orientation and aspect fitting are unchanged.
final class PresentationUpscaler {
    private let device: MTLDevice
    private var scaler: MTLFXSpatialScaler?
    private var output: MTLTexture?
    private var key: Key?
    private var failedKeys = Set<Key>()
    private(set) var lastDescription = "upscale: off"

    private struct Key: Hashable {
        let inputWidth: Int, inputHeight: Int, outputWidth: Int, outputHeight: Int
        let format: MTLPixelFormat
    }

    static func isSupported(on device: MTLDevice) -> Bool {
        MTLFXSpatialScalerDescriptor.supportsDevice(device)
    }

    init(device: MTLDevice) {
        self.device = device
    }

    /// Encodes the upscale and returns the larger texture, or nil to present
    /// `texture` as is.
    func upscale(
        _ texture: MTLTexture,
        mode: HDRUpscaleMode,
        targetPixelSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let input = CGSize(width: texture.width, height: texture.height)
        guard mode != .off, Self.isSupported(on: device),
              let size = mode.outputSize(input: input, target: targetPixelSize) else {
            lastDescription = "upscale: off (\(mode.rawValue), \(texture.width)x\(texture.height))"
            return nil
        }
        let key = Key(inputWidth: texture.width, inputHeight: texture.height,
                      outputWidth: Int(size.width), outputHeight: Int(size.height), format: texture.pixelFormat)
        guard !failedKeys.contains(key), let scaler = scaler(for: key),
              scaler.colorTextureUsage.isSubset(of: texture.usage), let output else {
            lastDescription = "upscale: unavailable for \(texture.width)x\(texture.height) to \(key.outputWidth)x\(key.outputHeight)"
            return nil
        }
        scaler.colorTexture = texture
        scaler.outputTexture = output
        scaler.inputContentWidth = texture.width
        scaler.inputContentHeight = texture.height
        scaler.encode(commandBuffer: commandBuffer)
        lastDescription = "upscale: MetalFX spatial \(texture.width)x\(texture.height) to \(key.outputWidth)x\(key.outputHeight) (\(mode.rawValue))"
        return output
    }

    private func scaler(for key: Key) -> MTLFXSpatialScaler? {
        if key == self.key, let scaler { return scaler }
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = key.inputWidth
        descriptor.inputHeight = key.inputHeight
        descriptor.outputWidth = key.outputWidth
        descriptor.outputHeight = key.outputHeight
        descriptor.colorTextureFormat = key.format
        descriptor.outputTextureFormat = key.format
        descriptor.colorProcessingMode = .hdr
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            failedKeys.insert(key)
            return nil
        }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: key.format, width: key.outputWidth, height: key.outputHeight, mipmapped: false
        )
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = scaler.outputTextureUsage.union(.shaderRead)
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            failedKeys.insert(key)
            return nil
        }
        texture.label = "HDRPlayer MetalFX upscale output"
        self.scaler = scaler
        self.output = texture
        self.key = key
        return scaler
    }
}
