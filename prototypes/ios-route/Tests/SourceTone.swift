import Foundation

@main
enum SourceToneTest {
    static func main() throws {
        // Write the actual source bytes for an independent WAV parser/level check.
        precondition(CommandLine.arguments.count == 2)
        try ReferenceTone.waveData().write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
