import AppKit

public enum NativePalette {
    // Keep system hue and appearance while making supporting text readable at small sizes.
    public static let secondary = NSColor(name: "FetchSecondaryText") { _ in NSColor.labelColor.withAlphaComponent(0.72) }
    public static let error = NSColor(name: "FetchErrorText") { _ in NSColor.systemRed.blended(withFraction: 0.22, of: .labelColor) ?? .systemRed }
}
