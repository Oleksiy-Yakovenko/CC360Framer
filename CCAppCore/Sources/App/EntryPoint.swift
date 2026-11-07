import Foundation

/// What the app's `main.swift` calls: the command line tools, otherwise the app itself.
public enum CC360Main {
    @MainActor
    public static func run() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--telemetry", args.count > 1 {
            guard let t = Telemetry.load(url: URL(fileURLWithPath: args[1])) else { print("no telemetry"); exit(1) }
            print("frames: \(t.count)  orientation \(t.orientation.count)  gravity \(t.gravity.count)")
            print("first q: \(t.orientation[0])  g: \(t.gravity[0])")
            print("gps: \(t.gps.map { "\($0.latitude), \($0.longitude)  alt \($0.altitude.map { String(format: "%.1f m", $0) } ?? "none")" } ?? "none")")
            print("last  q: \(t.orientation[t.count - 1])  g: \(t.gravity[t.count - 1])")
            exit(0)
        }
        if args.first == "--analysis-compare" {
            exit(AnalysisCompare.run(args: Array(args.dropFirst())))
        }
        if args.first == "--stab-test" {
            exit(StabTest.run(args: Array(args.dropFirst())))
        }
        if args.first == "--snapshot" {
            exit(Snapshot.run(args: Array(args.dropFirst())))
        }
        if args.first == "--batch-run" {
            BatchCLI.run(args: Array(args.dropFirst()))
        }
        CC360FramerApp.main()
    }
}
