import Foundation
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

    /// The "BrandAccent" asset catalog color resource.
    static let brandAccent = DeveloperToolsSupport.ColorResource(name: "BrandAccent", bundle: resourceBundle)

    /// The "BrandAccentSoft" asset catalog color resource.
    static let brandAccentSoft = DeveloperToolsSupport.ColorResource(name: "BrandAccentSoft", bundle: resourceBundle)

    /// The "BrandAccentStrong" asset catalog color resource.
    static let brandAccentStrong = DeveloperToolsSupport.ColorResource(name: "BrandAccentStrong", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

}

