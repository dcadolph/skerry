#if os(macOS)

    import CoreServices
    import Foundation

    /// LibraryWatcher reports file-system changes under a library root via FSEvents.
    ///
    /// Events are delivered coalesced on the main queue about a second after activity
    /// settles. The caller filters its own writes; the watcher only reports paths.
    final class LibraryWatcher {
        /// Running event stream.
        private var stream: FSEventStreamRef?
        /// Called on the main queue with the absolute paths FSEvents reported.
        private let onChange: ([String]) -> Void

        /// Starts watching a root folder; returns nil when the stream cannot be created.
        init?(root: URL, onChange: @escaping ([String]) -> Void) {
            self.onChange = onChange
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, rawPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue()
                let cStrings = rawPaths.assumingMemoryBound(
                    to: UnsafeMutablePointer<CChar>?.self
                )
                var paths: [String] = []
                for position in 0..<count {
                    if let cString = cStrings[position] {
                        paths.append(String(cString: cString))
                    }
                }
                watcher.onChange(paths)
            }
            guard let stream = FSEventStreamCreate(
                nil, callback, &context,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            ) else { return nil }
            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }

        deinit {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
    }

#endif
