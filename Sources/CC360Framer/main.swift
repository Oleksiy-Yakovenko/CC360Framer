import Foundation

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--telemetry", args.count > 1 {
    guard let t = Telemetry.load(url: URL(fileURLWithPath: args[1])) else { print("no telemetry"); exit(1) }
    print("frames: \(t.count)  orientation \(t.orientation.count)  gravity \(t.gravity.count)")
    print("first q: \(t.orientation[0])  g: \(t.gravity[0])")
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
CC360FramerApp.main()
