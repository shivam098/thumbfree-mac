import AVFoundation
import XCTest
@testable import ThumbFreeApp

/// One ThumbFree at a time (thumbfree-windows App.xaml.cs's single-instance mutex): the lock file in ThumbFree's
/// folder.
final class SingleInstanceTests: XCTestCase {
    private static let perl = "/usr/bin/perl"

    private var folder: TempFolder!

    override func setUp() {
        folder = TempFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    func testOnlyOneCopyHoldsTheLockUntilItLetsGo() throws {
        // Its folder is made if it's missing, as on the first launch.
        let path = folder.file("ThumbFree/instance.lock")
        let first = SingleInstance(path: path)
        let second = SingleInstance(path: path)

        XCTAssertTrue(try first.acquire())
        XCTAssertTrue(try first.acquire())
        XCTAssertFalse(try second.acquire())
        first.release()
        XCTAssertTrue(try second.acquire())
        second.release()
    }

    func testAnotherProcessCantTakeTheLockAndOneThatEndsLeavesNoneBehind() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.perl), "no perl to hold the lock")
        let path = folder.file("instance.lock")
        let mine = SingleInstance(path: path)

        // Another copy can't have it while this one holds it, and gets it once this one lets go.
        XCTAssertTrue(try mine.acquire())
        XCTAssertEqual(try TestFiles.run(Self.perl, ["-e", Self.tryLock, path]).status, 1)
        mine.release()
        XCTAssertEqual(try TestFiles.run(Self.perl, ["-e", Self.tryLock, path]).status, 0)

        // A copy that holds it and is killed lets go of it without unlocking.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: Self.perl)
        holder.arguments = ["-e", Self.holdLock, path]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        defer {
            if holder.isRunning {
                holder.terminate()
            }
        }

        XCTAssertEqual(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self), "locked\n")
        XCTAssertFalse(try mine.acquire())
        holder.terminate()
        holder.waitUntilExit()
        XCTAssertTrue(try mine.acquire())
        mine.release()
    }

    /// Exits 0 when it could take the lock (flock, as ThumbFree does), 1 when another holds it.
    private static let tryLock = """
        use Fcntl ":flock"; open(my $f, ">>", $ARGV[0]) or die; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1);
        """

    /// Takes the lock, says so, and waits to be killed.
    private static let holdLock = """
        use Fcntl ":flock"; $| = 1; open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; \
        print "locked\\n"; sleep 30;
        """
}

/// The start and stop tones (thumbfree-windows `SoundFeedback`): the same notes, as WAV data AVFoundation plays.
final class SoundFeedbackTests: XCTestCase {
    func testEachCueIsAShortQuietToneThatFadesInAsAWAVFile() throws {
        let cues: [(cue: SoundFeedback.Cue, samples: Int)] = [
            (.wake, 1_543 + 1_984), (.startTyping, 2_425), (.stopTyping, 1_543 + 1_984), (.standby, 1_764),
        ]
        for (cue, count) in cues {
            let samples = SoundFeedback.render(SoundFeedback.notes(cue))
            XCTAssertEqual(samples.count, count, "\(cue)")
            XCTAssertEqual(samples.first, 0, "\(cue)")
            XCTAssertLessThanOrEqual(samples.map { abs(Int($0)) }.max() ?? 0, 3_932, "\(cue)")

            let wav = SoundFeedback.wav(samples)
            XCTAssertEqual(wav.count, 44 + count * 2)
            XCTAssertEqual(Array(wav.prefix(4)), Array("RIFF".utf8))
            let player = try AVAudioPlayer(data: wav)
            XCTAssertEqual(player.format.sampleRate, 22_050)
            XCTAssertEqual(player.format.channelCount, 1)
            XCTAssertEqual(player.duration, Double(count) / 22_050, accuracy: 0.001)
        }
    }
}
