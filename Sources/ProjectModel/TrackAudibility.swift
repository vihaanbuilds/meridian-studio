public enum TrackAudibility {
    public static func audibleTracks(in tracks: [Track]) -> [Track] {
        let soloed = tracks.filter { $0.solo }
        if !soloed.isEmpty { return soloed }
        return tracks.filter { !$0.muted }
    }
}
