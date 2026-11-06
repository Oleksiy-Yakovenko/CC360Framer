import Foundation

/// Parsing and formatting of a typed size (points, percent) for the editable size combo boxes. Pure, so it is tested.
enum SizeInput {
    /// The number in `text` clamped to `range` and rounded to a multiple of `step`; nil when it is not a finite number.
    /// Accepts surrounding spaces, a decimal comma and a trailing unit ("pt", "px", "%").
    static func parse(_ text: String, range: ClosedRange<Double>, step: Double = 1) -> Double? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for unit in ["pt", "px", "%"] where t.hasSuffix(unit) { t = String(t.dropLast(unit.count)).trimmingCharacters(in: .whitespaces) }
        guard !t.isEmpty, let v = Double(t.replacingOccurrences(of: ",", with: ".")), v.isFinite else { return nil }
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let snapped = ((clamped / step).rounded() * step * 1e6).rounded() / 1e6   // no float noise like 5.500000000000001
        return min(max(snapped, range.lowerBound), range.upperBound)
    }

    /// "64" for whole numbers, otherwise one decimal ("5.5").
    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// `v` with exactly `decimals` fractional digits ("2.5", "0.70"); `decimals` 0 gives whole numbers. Used by the slider value fields.
    static func format(_ v: Double, decimals: Int) -> String {
        String(format: "%.\(max(decimals, 0))f", v)
    }

    /// Which text of an editable combo box is the user's choice. A list pick (`pickedItem`, reported by the selection
    /// notification) wins; otherwise the text being edited (`editorText`) or the field value (`stringValue`). The selected
    /// item's index is deliberately ignored: it goes stale when the user types a value that is not a preset, and reading
    /// it then silently restores the old preset (the "size is ignored" bug).
    static func chosenText(pickedItem: String?, editorText: String?, stringValue: String) -> String {
        pickedItem ?? editorText ?? stringValue
    }
}
