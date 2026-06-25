#if os(macOS)
    import Foundation

    /// Filters the firehose of harmless CoreAudio / Voice-Processing-I/O (VPIO)
    /// chatter that macOS 26 writes straight to **stderr** (`fprintf`, not os_log)
    /// while the voice-processing audio unit starts up and runs.
    ///
    /// Lines like `throwing -10877`, `vpStrategyManager … GetProperty`,
    /// `HALC_ProxyIOContext … StartIO failed (error 35)`, `AUVPAggregate Timeout
    /// waiting for streams`, `Voice_Processor … failed to run downlink DSP`,
    /// `IOWorkLoop: skipping cycle due to overload`, etc. are an Apple VPIO bug on
    /// macOS 26 (LiveKit issue #1022). They're **cosmetic** — audio works
    /// regardless — but they bury our real logs.
    ///
    /// We dup a pipe over `STDERR_FILENO`, read it on a background thread, drop
    /// lines matching the known-noise substrings, and pass everything else (Swift
    /// prints, LiveKit SDK logs, genuine errors) through to the real stderr (a saved
    /// dup of fd 2, still wired to Xcode's console). Install once, as early as
    /// possible — before the audio engine starts.
    ///
    /// The pump thread is **allocation-free and reentrancy-safe**: it uses only raw
    /// C buffers, a manual substring scan, and `write()`. No `Data`/`String`/`Array`
    /// work happens per line — that crashed (EXC_BREAKPOINT) when CoreAudio floods
    /// stderr while the Swift heap is busy.
    enum AudioLogNoiseFilter {
        /// Substrings that mark a line as known VPIO/CoreAudio startup/runtime noise.
        /// Kept deliberately specific to these subsystems so real logs survive.
        private static let noiseMarkers: [String] = [
            "throwing -108", // -10877 / -10874 render/IO errors
            "render err: -108",
            "vp::vx", // Voice_Processor / adapter / dsp graph
            "Voice_Processor",
            "Far_End_Voice_Proc",
            "vpStrategyManager",
            "ProcessDownlinkAudio",
            "ProcessUplinkAudio",
            "AUVPUtilities",
            "SetDeviceMuteState",
            "AUVPAggregate",
            "audioanalyticsd",
            "Process is sandboxed but",
            "AudioDSPGraph",
            "AVAudioNotificationCenter",
            "Failed to configure notification center",
            "HALC_ProxyIOContext",
            "HALC_ProxyObjectMap",
            "HALC_ShellDevice",
            "HALC_ShellObject",
            "HALB_IOThread",
            "AudioHardware-mac-imp",
            "AudioObjectGetPropertyData",
            "AudioObjectRemovePropertyListener",
            "AVCaptureHALDevice",
            "AddInstanceForFactory",
            "kAudioUnitErr_TooManyFramesToProcess",
            "aumx/mcmx/appl",
            "IOWorkLoop: skipping cycle",
            "StartAndWaitForState returned error",
            "Reporter disconnected",
            "Unable to obtain a task name port right",
            "DetachedSignatures",
            "os_unix.c",
            "cannot open file at line",
            "Fig assert",
            "signalled err=",
        ]

        private static var installed = false

        static func install() {
            guard !installed else { return }
            installed = true

            // Keep a handle to the *real* stderr to write the surviving lines back.
            let realStderr = dup(STDERR_FILENO)
            guard realStderr >= 0 else { return }

            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { close(realStderr); return }
            let readFD = fds[0]
            let writeFD = fds[1]

            // Route everything written to stderr into our pipe.
            guard dup2(writeFD, STDERR_FILENO) >= 0 else {
                close(readFD)
                close(writeFD)
                close(realStderr)
                return
            }
            close(writeFD) // STDERR_FILENO now holds the pipe's write end.

            // Precompute markers as plain UTF-8 byte arrays ONCE, here on the
            // calling thread, so the pump thread does zero Swift-heap work.
            let markers: [[UInt8]] = noiseMarkers.map { Array($0.utf8) }

            Thread.detachNewThread {
                pump(readFD: readFD, outFD: realStderr, markers: markers)
            }
        }

        // MARK: - Pump (raw C, allocation-free)

        private static func pump(readFD: Int32, outFD: Int32, markers: [[UInt8]]) {
            let lineCap = 1 << 16 // accumulates one line (a long-line guard caps it)
            let line = UnsafeMutablePointer<UInt8>.allocate(capacity: lineCap)
            defer { line.deallocate() }
            var lineLen = 0

            let chunkCap = 8192
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkCap)
            defer { chunk.deallocate() }

            let newline: UInt8 = 0x0A

            while true {
                let n = read(readFD, chunk, chunkCap)
                if n <= 0 { break }
                var i = 0
                while i < n {
                    let byte = chunk[i]
                    if lineLen < lineCap {
                        line[lineLen] = byte
                        lineLen += 1
                    } else {
                        // Pathologically long line: flush what we have, start over.
                        emit(line, lineLen, outFD: outFD, markers: markers)
                        line[0] = byte
                        lineLen = 1
                    }
                    if byte == newline {
                        emit(line, lineLen, outFD: outFD, markers: markers)
                        lineLen = 0
                    }
                    i += 1
                }
            }
            if lineLen > 0 { emit(line, lineLen, outFD: outFD, markers: markers) }
        }

        private static func emit(_ line: UnsafeMutablePointer<UInt8>, _ len: Int,
                                 outFD: Int32, markers: [[UInt8]]) {
            if len == 0 { return }
            for marker in markers where contains(line, len, marker) { return } // drop noise

            var off = 0
            while off < len {
                let w = write(outFD, line + off, len - off)
                if w <= 0 { break }
                off += w
            }
        }

        /// Manual, allocation-free substring search (lines are short; markers few).
        private static func contains(_ hay: UnsafeMutablePointer<UInt8>, _ hayLen: Int,
                                     _ needle: [UInt8]) -> Bool {
            let nLen = needle.count
            if nLen == 0 || nLen > hayLen { return false }
            let last = hayLen - nLen
            var i = 0
            while i <= last {
                var k = 0
                while k < nLen, hay[i + k] == needle[k] { k += 1 }
                if k == nLen { return true }
                i += 1
            }
            return false
        }
    }
#endif
