import AppKit
import CoreGraphics
import HDRCore

public struct DisplayCapabilities: Equatable, Sendable {
    public let screenName: String
    public let potentialHeadroom: Float
    public let currentHeadroom: Float
    public let referenceHeadroom: Float
    public let refreshRate: Double?

    public var isEDRCapable: Bool {
        potentialHeadroom > 1.0 + 0.001
    }

    /// Direct EDR policy always uses physical *current* headroom and never
    /// substitutes potential capability. Potential is capability metadata,
    /// not a safe component ceiling at the current brightness/power state.
    public var usableHeadroom: Float {
        guard isEDRCapable else { return 1 }
        return min(max(currentHeadroom, 1), max(potentialHeadroom, 1))
    }

    public var isActivelyUsingEDR: Bool {
        isEDRCapable && currentHeadroom > 1.0 + 0.001
    }

    /// The presentation shader emits BT.2020 only while EDR is physically
    /// active. Potential capability alone is insufficient because the SDR
    /// fallback branch emits linear sRGB/BT.709 primaries.
    public var presentsExtendedBT2020: Bool {
        isActivelyUsingEDR
    }

    public static let fallback = DisplayCapabilities(
        screenName: "Unknown display",
        potentialHeadroom: 1,
        currentHeadroom: 1,
        referenceHeadroom: 1,
        refreshRate: nil
    )

    public init(
        screenName: String,
        potentialHeadroom: Float,
        currentHeadroom: Float,
        referenceHeadroom: Float,
        refreshRate: Double?
    ) {
        self.screenName = screenName
        self.potentialHeadroom = potentialHeadroom
        self.currentHeadroom = currentHeadroom
        self.referenceHeadroom = referenceHeadroom
        self.refreshRate = refreshRate
    }

    @MainActor
    public static func read(from screen: NSScreen?) -> DisplayCapabilities {
        guard let screen else { return .fallback }
        let potential = Float(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        let current = Float(screen.maximumExtendedDynamicRangeColorComponentValue)
        let reference = Float(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)
        let name = (screen.localizedName.isEmpty ? "Unnamed display" : screen.localizedName)
        return DisplayCapabilities(
            screenName: name,
            potentialHeadroom: finiteOrOne(potential),
            currentHeadroom: finiteOrOne(current),
            referenceHeadroom: finiteOrOne(reference),
            refreshRate: displayRefreshRate(for: screen)
        )
    }

    public func configuration(for base: HDRConfiguration) -> HDRConfiguration {
        var configuration = base
        configuration.outputMode = .edr
        if !isActivelyUsingEDR {
            // Safe SDR fallback: preserve the original SDR linear structure;
            // the presentation shader converts BT.2020 linear to SDR linear
            // sRGB and clamps only in this explicitly SDR path.
            configuration.highlightStrength = 0
            configuration.contrastStrength = 0
            configuration.saturationCompensation = 0
            configuration.shadowProtection = 0
        }
        return configuration
    }

    public var displayState: HDRDisplayState {
        HDRDisplayState(
            currentEDRHeadroom: isActivelyUsingEDR ? usableHeadroom : 1,
            potentialEDRHeadroom: isEDRCapable ? potentialHeadroom : 1
        )
    }

    public var logDescription: String {
        "Display: \(screenName), potential EDR headroom: \(format(potentialHeadroom)), current EDR headroom: \(format(currentHeadroom)), reference EDR headroom: \(format(referenceHeadroom)), refresh: \(refreshRate.map { format($0) } ?? "unknown") Hz, mode: \(isActivelyUsingEDR ? "EDR" : "SDR fallback")"
    }

    public static func colorSpace(forEDR: Bool) -> CGColorSpace? {
        let name: CFString = forEDR
            ? CGColorSpace.extendedLinearITUR_2020
            : CGColorSpace.extendedLinearSRGB
        return CGColorSpace(name: name)
    }

    private static func finiteOrOne(_ value: Float) -> Float {
        value.isFinite && value >= 1 ? value : 1
    }

    @MainActor
    private static func displayRefreshRate(for screen: NSScreen) -> Double? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        return CGDisplayCopyDisplayMode(displayID)?.refreshRate
    }

    private func format(_ value: Float) -> String {
        String(format: "%.2f", value)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
