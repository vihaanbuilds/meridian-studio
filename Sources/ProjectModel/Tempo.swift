public enum Tempo {
    public static func seconds(forBeats beats: Double, tempo: Double) -> Double {
        beats * 60.0 / tempo
    }

    public static func beats(forSeconds seconds: Double, tempo: Double) -> Double {
        seconds * tempo / 60.0
    }
}
