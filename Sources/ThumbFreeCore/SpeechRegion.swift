import Foundation

/// A stretch of speech, in seconds from the start of the audio (C#'s `(TimeSpan Start, TimeSpan End)`), as a
/// voice-activity detector finds it.
public struct SpeechRegion: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}
