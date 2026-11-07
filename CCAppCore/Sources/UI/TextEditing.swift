import AppKit

/// Whether a first responder is a text editor (field editor or text view) that must receive unmodified keys before menu shortcuts.
enum TextEditing {
    static func isEditing(_ responder: NSResponder) -> Bool { responder is NSText }
}
