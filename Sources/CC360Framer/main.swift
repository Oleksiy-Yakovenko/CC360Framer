import Foundation

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "--snapshot" {
    exit(Snapshot.run(args: Array(args.dropFirst())))
}
CC360FramerApp.main()
