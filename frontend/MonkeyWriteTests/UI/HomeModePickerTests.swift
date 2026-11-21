import SwiftUI
import XCTest
@testable import MonkeyWrite

/// Changes the home screen's saved mode while it is on screen and checks, by
/// pixel, that the yellow capsule follows the selection.
/// Screenshots go to NSTemporaryDirectory()/HomeShots (printed as HOME_SHOT).
@MainActor
final class HomeModePickerTests: XCTestCase {
    private var savedMode: String?

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.string(forKey: SettingsStorage.modeKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedMode, forKey: SettingsStorage.modeKey)
        super.tearDown()
    }

    private func host() throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        window.rootViewController = UIHostingController(rootView: HomeView().preferredColorScheme(.dark).tint(Theme.accent))
        window.isHidden = false
        return window
    }

    private func settle() async { try? await Task.sleep(for: .seconds(0.5)) }

    /// Whether the capsule behind a mode button is drawn yellow, sampled in
    /// the button's left padding (left of its icon, clear of the text).
    private func isHighlighted(at point: CGPoint, in window: UIWindow) -> Bool {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        // Draw the one pixel into a known RGBA layout.
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let cgImage = image.cgImage,
                  let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            let scale = image.scale
            // Core Graphics' origin is bottom left: place the sampled pixel at (0, 0).
            context.draw(cgImage, in: CGRect(x: -point.x * scale,
                                             y: -(CGFloat(cgImage.height) - point.y * scale - 1),
                                             width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            return true
        }
        guard drawn else { return false }
        let (r, g, b) = (CGFloat(rgba[0]) / 255, CGFloat(rgba[1]) / 255, CGFloat(rgba[2]) / 255)
        return r > 0.85 && g > 0.65 && b < 0.45
    }

    private func shoot(_ window: UIWindow, _ name: String) throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("HomeShots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = folder.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("HOME_SHOT \(url.path)")
    }

    // Points inside each capsule's left padding on a 1032 x 1376 window
    // (the side-by-side Mode / Subject layout).
    private let timedSpot = CGPoint(x: 241, y: 762)
    private let passageSpot = CGPoint(x: 410, y: 762)

    /// The buttons set `@AppStorage(SettingsStorage.modeKey)`, which writes
    /// this key; the redraw comes from the store's change notification, so
    /// writing the key while the screen is up exercises the same path.
    func testHighlightFollowsTheSelectedMode() async throws {
        UserDefaults.standard.set(TestMode.oneMinute.rawValue, forKey: SettingsStorage.modeKey)
        let window = try host()
        defer { window.isHidden = true }
        await settle()
        try shoot(window, "home-1-timed")
        XCTAssertTrue(isHighlighted(at: timedSpot, in: window), "60 Seconds starts highlighted")
        XCTAssertFalse(isHighlighted(at: passageSpot, in: window))

        UserDefaults.standard.set(TestMode.passage.rawValue, forKey: SettingsStorage.modeKey)
        await settle()
        try shoot(window, "home-2-passage")
        XCTAssertTrue(isHighlighted(at: passageSpot, in: window), "Highlight moved to Passage")
        XCTAssertFalse(isHighlighted(at: timedSpot, in: window), "60 Seconds no longer highlighted")

        UserDefaults.standard.set(TestMode.oneMinute.rawValue, forKey: SettingsStorage.modeKey)
        await settle()
        try shoot(window, "home-3-timed-again")
        XCTAssertTrue(isHighlighted(at: timedSpot, in: window), "Highlight moved back")
        XCTAssertFalse(isHighlighted(at: passageSpot, in: window))
    }
}
