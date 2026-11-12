import Foundation

/// A launched app's output, which `launch` redirects to a file.
enum AppOutputStream: String, CaseIterable, Sendable {
    case stdout, stderr
}

/// The files `launch` redirects an app's output to.
struct AppOutput {
    /// Unbuffers stdout, as Xcode does, so each line reaches its file as it is printed.
    static let environment = ["NSUnbufferedIO": "YES"]

    let files: [AppOutputStream: URL]

    var launchOptions: [String] {
        AppOutputStream.allCases.compactMap { stream in files[stream].map { "--\(stream.rawValue)=\($0.path)" } }
    }
}

/// The app `logs` reads by default and where each cursor stands, in a file that the command line and the daemon both
/// update, so each access reads it afresh.
struct LogStore {
    struct App: Codable, Equatable {
        let bundleID: String
        let pid: Int?
        let launchedAt: Date
        let stdoutPath: String?
        let stderrPath: String?
        /// The executable's name, resolved on first read.
        var process: String?

        func path(of stream: AppOutputStream) -> String? { stream == .stdout ? stdoutPath : stderrPath }
    }

    struct Cursor: Codable, Equatable {
        var date: Date
        var crashesCheckedAt: Date?
        var stdoutOffset: UInt64 = 0
        var stderrOffset: UInt64 = 0

        subscript(offset stream: AppOutputStream) -> UInt64 {
            get { stream == .stdout ? stdoutOffset : stderrOffset }
            set {
                if stream == .stdout { stdoutOffset = newValue } else { stderrOffset = newValue }
            }
        }
    }

    struct Contents: Codable, Equatable {
        var app: App?
        var cursors: [String: Cursor] = [:]
    }

    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func read() -> Contents {
        (try? JSONDecoder().decode(Contents.self, from: Data(contentsOf: url))) ?? Contents()
    }

    func update(_ change: (inout Contents) -> Void) {
        var contents = read()
        change(&contents)
        try? JSONEncoder.line.encode(contents).write(to: url, options: .atomic)
    }
}
