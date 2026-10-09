import AppKit
import CoreGraphics
import Foundation

/// A user-selectable display that ScreenCaptureKit can record.
public struct CaptureDisplay: Identifiable, Equatable, Hashable, Sendable {
    public var id: UInt32
    public var name: String
    public var width: Int
    public var height: Int
    public var isMain: Bool

    public init(id: UInt32, name: String, width: Int, height: Int, isMain: Bool) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.isMain = isMain
    }

    public var aspectRatio: CGFloat {
        CGFloat(width) / max(CGFloat(height), 1)
    }

    public var menuTitle: String {
        let size = "\(width)×\(height)"
        if isMain {
            return "\(name) (Main) · \(size)"
        }
        return "\(name) · \(size)"
    }

    /// Connected `NSScreen`s. Cheap enough to call on first layout without ScreenCaptureKit.
    public static func connectedScreens() -> [CaptureDisplay] {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            guard let displayID = number?.uint32Value else { return nil }
            let width = Int(CGDisplayPixelsWide(displayID))
            let height = Int(CGDisplayPixelsHigh(displayID))
            guard isSelectableCaptureTarget(displayID: displayID, width: width, height: height) else {
                return nil
            }
            return CaptureDisplay(
                id: displayID,
                name: screen.localizedName,
                width: width,
                height: height,
                isMain: displayID == mainID
            )
        }
    }

    public static func nsScreen(forDisplayID displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }
    }

    public static func localizedName(forDisplayID displayID: UInt32) -> String {
        if let name = nsScreen(forDisplayID: displayID)?.localizedName, !name.isEmpty {
            return name
        }
        return "Display \(displayID)"
    }

    public static func backingScaleFactor(forDisplayID displayID: UInt32) -> CGFloat {
        nsScreen(forDisplayID: displayID)?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    /// Whether this CGDisplay is a capture target QuickTime-style: a connected
    /// screen, not a Mission Control Space, and not a mirrored copy.
    public static func isSelectableCaptureTarget(displayID: UInt32, width: Int, height: Int) -> Bool {
        isSelectableCaptureTarget(
            displayID: displayID,
            width: width,
            height: height,
            isOnline: CGDisplayIsOnline(displayID) != 0,
            isActive: CGDisplayIsActive(displayID) != 0,
            mirrorMasterID: CGDisplayIsInMirrorSet(displayID) != 0 ? CGDisplayMirrorsDisplay(displayID) : nil
        )
    }

    public static func isSelectableCaptureTarget(displayID: UInt32,
                                                 width: Int,
                                                 height: Int,
                                                 isOnline: Bool,
                                                 isActive: Bool,
                                                 mirrorMasterID: UInt32?) -> Bool {
        guard width > 0, height > 0 else { return false }
        guard isOnline, isActive else { return false }
        if let master = mirrorMasterID, master != 0, master != displayID {
            return false
        }
        return true
    }
}

/// Picks which display to capture when the user has a preferred ID, or falls back.
public enum CaptureDisplayResolver {
    public static func resolveID(preferred: UInt32?,
                                 available: [UInt32],
                                 main: UInt32) -> UInt32? {
        if let preferred, available.contains(preferred) {
            return preferred
        }
        if available.contains(main) {
            return main
        }
        return available.first
    }
}
