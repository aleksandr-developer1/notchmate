import Foundation

extension FileHandle {
    /// Reads until EOF. Unlike the deprecated `readDataToEndOfFile()`, a failed read
    /// returns what arrived so far instead of raising an Objective-C exception (a crash).
    func readAll() -> Data {
        (try? readToEnd()) ?? Data()
    }
}
