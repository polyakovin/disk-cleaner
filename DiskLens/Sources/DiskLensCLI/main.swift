import Foundation
import DiskLensCore

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first, !path.hasPrefix("--") else {
    FileHandle.standardError.write(Data("Usage: disklens-cli /path/to/folder [--text]\n".utf8))
    exit(2)
}
do {
    let report = try DiskScanner().scan(URL(fileURLWithPath: path))
    print(args.contains("--text") ? report.text() : try report.json())
    exit(report.isPartial ? 1 : 0)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(2)
}
