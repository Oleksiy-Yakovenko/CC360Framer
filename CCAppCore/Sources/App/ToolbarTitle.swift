/// Text of the window toolbar's title item.
enum ToolbarTitle {
    static func text(appName: String, fileName: String?) -> String {
        guard let name = fileName, !name.isEmpty else { return appName }
        return "\(appName) - \(name)"
    }
}
