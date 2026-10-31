import HDRCore
import XCTest
@testable import HDRPlayerKit

final class SDRInputInterpretationOptionTests: XCTestCase {
    func testDefaultKeepsProductionInterpretation() throws {
        let options = try PlayerOptions.parse(arguments: ["HDRPlayer", "/tmp/video.mp4"])
        XCTAssertEqual(options.sdrInputInterpretation, .sceneReferredInverseOETF)
        XCTAssertEqual(try options.baseConfiguration().sdrInputInterpretation, .sceneReferredInverseOETF)
    }

    func testBT1886OptionReachesCoreConfiguration() throws {
        let options = try PlayerOptions.parse(arguments: [
            "HDRPlayer", "/tmp/video.mp4", "--sdr-input", "BT1886"
        ])
        XCTAssertEqual(options.sdrInputInterpretation, .bt1886)
        let configuration = try options.baseConfiguration()
        XCTAssertEqual(configuration.sdrInputInterpretation, .bt1886)

        // The no-EDR fallback derives from the base configuration and must not
        // silently revert the selected input interpretation.
        let sdrDisplay = DisplayCapabilities.fallback
        XCTAssertEqual(sdrDisplay.configuration(for: configuration).sdrInputInterpretation, .bt1886)
    }

    func testExplicitInverseOETFOptionIsAccepted() throws {
        let options = try PlayerOptions.parse(arguments: [
            "HDRPlayer", "/tmp/video.mp4", "--sdr-input", "scene-inverse-oetf"
        ])
        XCTAssertEqual(options.sdrInputInterpretation, .sceneReferredInverseOETF)
    }

    func testUnknownInterpretationIsRejected() {
        XCTAssertThrowsError(try PlayerOptions.parse(arguments: [
            "HDRPlayer", "/tmp/video.mp4", "--sdr-input", "gamma2.2"
        ])) { error in
            XCTAssertEqual(error as? HDRPlayerCLIError,
                           .invalidOption("unsupported SDR input interpretation: gamma2.2"))
        }
    }

    func testUsageDocumentsOption() {
        XCTAssertTrue(PlayerOptions.usage.contains("--sdr-input scene-inverse-oetf|bt1886"))
    }
}
