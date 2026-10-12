import Foundation

// The shared Swift sources look up their resources with SwiftPM's `Bundle.module`. CocoaPods has no such thing,
// so this file (compiled only in this pod, not in the Swift package) points it at the pod's resource bundle.
private final class FountisBundleToken {}

extension Bundle {
    static var module: Bundle {
        let here = Bundle(for: FountisBundleToken.self)
        for base in [here.resourceURL, Bundle.main.resourceURL] {
            if let url = base?.appendingPathComponent("FountisConnect.bundle"), let b = Bundle(url: url) { return b }
        }
        return here
    }
}
