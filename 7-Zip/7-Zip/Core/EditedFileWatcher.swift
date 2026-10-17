import Foundation

/// Watches files that were extracted from an archive so they can be opened in an
/// external application, and reports back when one of them is saved.
///
/// This is what makes "open a file inside the archive, edit it, save" work the way
/// it does in the Windows file manager: the edited copy lives in a temp folder, and
/// when the editor writes to it we offer to put it back into the archive.
final class EditedFileWatcher {

    struct WatchedFile {
        let archivePath: String
        /// Path of the entry inside the archive, e.g. "docs/readme.txt"
        let entryPath: String
        /// The extracted copy on disk that the editor has open
        let localURL: URL
        let password: String?
    }

    static let shared = EditedFileWatcher()

    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var watched: [URL: WatchedFile] = [:]
    private var lastModified: [URL: Date] = [:]
    private let queue = DispatchQueue(label: "com.donishsoft.tajarchive.filewatcher")

    /// Called on the main thread when a watched file has been saved.
    var onFileChanged: ((WatchedFile) -> Void)?

    private init() {}

    func watch(_ file: WatchedFile) {
        stopWatching(file.localURL)

        let descriptor = open(file.localURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            AppLogger.shared.log(message: "⚠️ Could not watch \(file.localURL.lastPathComponent) for edits", level: .error)
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .extend, .delete],
            queue: queue
        )

        lastModified[file.localURL] = modificationDate(of: file.localURL)

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let url = file.localURL

            // Editors often write via a temp file and rename, which fires several
            // events; settle briefly and compare timestamps so we prompt once.
            self.queue.asyncAfter(deadline: .now() + 0.4) {
                guard let current = self.modificationDate(of: url) else { return }
                let previous = self.lastModified[url]
                guard previous == nil || current > previous! else { return }
                self.lastModified[url] = current

                guard let info = self.watched[url] else { return }
                DispatchQueue.main.async {
                    self.onFileChanged?(info)
                }
            }
        }

        source.setCancelHandler {
            close(descriptor)
        }

        sources[file.localURL] = source
        watched[file.localURL] = file
        source.resume()

        AppLogger.shared.log(message: "👁 Watching \(file.entryPath) for edits", level: .info)
    }

    func stopWatching(_ url: URL) {
        sources[url]?.cancel()
        sources[url] = nil
        watched[url] = nil
        lastModified[url] = nil
    }

    func stopAll() {
        for (url, _) in sources { stopWatching(url) }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
