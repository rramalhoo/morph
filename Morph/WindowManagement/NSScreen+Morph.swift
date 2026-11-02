import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Survives reboots and reconnects, unlike `CGDirectDisplayID`.
    var stableIdentifier: String {
        guard let displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return localizedName
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var metrics: ScreenMetrics {
        ScreenMetrics(frame: frame, visibleFrame: visibleFrame, safeAreaTop: safeAreaInsets.top,
                      auxiliaryTopLeft: auxiliaryTopLeftArea, auxiliaryTopRight: auxiliaryTopRightArea,
                      scale: backingScaleFactor)
    }

    var candidate: DisplayCandidate {
        DisplayCandidate(identifier: stableIdentifier, name: localizedName,
                         hasNotch: NotchGeometry.resolve(metrics).hasPhysicalNotch,
                         isBuiltIn: displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false,
                         isMain: self == NSScreen.main)
    }
}
