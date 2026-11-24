import AVFoundation
import SwiftUI

/// A song people can add to a post: a 30-second clip, streamed.
struct Song: Identifiable, Hashable {
    let id: String, title: String, mood: String
    /// Where in the song's longer clip the part that plays starts, when the poster chose (seconds). Not chosen: the
    /// song's usual 30 seconds.
    var start: Double? = nil
    var url: URL? { URL(string: Music.base + id + ".m4a") }
    /// The longer clip a part is chosen from, for songs that have one.
    var longURL: URL? { Music.long[id] == nil ? nil : URL(string: Music.base + "long/" + id + ".m4a") }
    /// Where the part that plays starts in the longer clip.
    var from: Double {
        guard let l = Music.long[id] else { return 0 }
        return min(max(0, start ?? l.at), max(0, l.len - 5))
    }
    /// As a post carries it: which song, and the part of it if one was chosen (a build from before that plays the usual part).
    var tag: JSON {
        var j: JSON = ["id": id, "title": title]
        if let start { j["start"] = (start * 10).rounded() / 10 }
        return j
    }
    /// How much of a song plays before it goes round again.
    static let part = 30.0

    /// Who made it, where that's known for certain (18 Nov). Only HoliznaCC0's are: the OpenGameArt songs name who
    /// put them up, not always who wrote them, and FreePD kept no artist. Where it isn't known, the mood stands in.
    var artist: String? { Music.holizna.contains(id) ? "HoliznaCC0" : nil }
    /// What's shown before the title: the artist, or else the mood.
    var byline: String { artist ?? mood }
}

/// The songs for posts. Every one was released as public domain (CC0): FreePD's collection, HoliznaCC0's lofi, and
/// metal and punk from OpenGameArt pages marked CC0 only (music/SOURCES.json has each one's page). Cut to 30 seconds by
/// design/music_clips.py; the clips and the record of where each came from are in music/ at the top of the repo,
/// which the site's GitHub Pages serves. A post carries its song as extra.song {id, title}.
enum Music {
    static let base = "https://domchivers.github.io/cheat-day/music/"
    static let moods = ["Upbeat", "Gym", "Epic", "Chill", "Lofi", "Metal", "Hardcore", "Funny"]
    /// HoliznaCC0's songs (music/SOURCES.json, collection "HoliznaCC0").
    static let holizna: Set<String> = ["2-hour-delay", "winter-blues", "first-snow", "snow-drift", "fire-place", "kids", "spring-at-last",
                                       "sense-of-purpose", "april-showers", "deja-vu", "boredom", "anxiety", "love", "old-age", "dreams"]
    static let all: [Song] = [
        Song(id: "advertime", title: "Advertime", mood: "Upbeat"),
        Song(id: "and-just-like-that", title: "And Just Like That", mood: "Upbeat"),
        Song(id: "city-sunshine", title: "City Sunshine", mood: "Upbeat"),
        Song(id: "funshine", title: "Funshine", mood: "Upbeat"),
        Song(id: "happy-whistling-ukulele", title: "Happy Whistling Ukulele", mood: "Upbeat"),
        Song(id: "inspiration", title: "Inspiration", mood: "Upbeat"),
        Song(id: "motions", title: "Motions", mood: "Upbeat"),
        Song(id: "pickled-pink", title: "Pickled Pink", mood: "Upbeat"),
        Song(id: "screen-saver", title: "Screen Saver", mood: "Upbeat"),
        Song(id: "ukulele-song", title: "Ukulele Song", mood: "Upbeat"),
        Song(id: "from-page-to-practice", title: "From Page to Practice", mood: "Upbeat"),
        Song(id: "inventing-flight", title: "Inventing Flight", mood: "Upbeat"),
        Song(id: "be-chillin", title: "Be Chillin", mood: "Upbeat"),
        Song(id: "backbeat", title: "Backbeat", mood: "Gym"),
        Song(id: "beat-one", title: "Beat One", mood: "Gym"),
        Song(id: "chronos", title: "Chronos", mood: "Gym"),
        Song(id: "favorite", title: "Favorite", mood: "Gym"),
        Song(id: "fireworks", title: "Fireworks", mood: "Gym"),
        Song(id: "hear-what-they-say", title: "Hear What They Say", mood: "Gym"),
        Song(id: "hippety-hop", title: "Hippety Hop", mood: "Gym"),
        Song(id: "arpent", title: "Arpent", mood: "Gym"),
        Song(id: "beat-thee", title: "Beat Thee", mood: "Gym"),
        Song(id: "action-strike", title: "Action Strike", mood: "Gym"),
        Song(id: "city-run", title: "City Run", mood: "Gym"),
        Song(id: "driving-concern", title: "Driving Concern", mood: "Gym"),
        Song(id: "epic-boss-battle", title: "Epic Boss Battle", mood: "Epic"),
        Song(id: "heroic-adventure", title: "Heroic Adventure", mood: "Epic"),
        Song(id: "hit-n-smash", title: "Hit n Smash", mood: "Epic"),
        Song(id: "new-hero-in-town", title: "New Hero in Town", mood: "Epic"),
        Song(id: "strength-of-the-titans", title: "Strength of the Titans", mood: "Epic"),
        Song(id: "video-game-blockbuster", title: "Video Game Blockbuster", mood: "Epic"),
        Song(id: "meditating-beat", title: "Meditating Beat", mood: "Chill"),
        Song(id: "study-and-relax", title: "Study and Relax", mood: "Chill"),
        Song(id: "3-am-west-end", title: "3 am West End", mood: "Chill"),
        Song(id: "relaxing-ballad", title: "Relaxing Ballad", mood: "Chill"),
        Song(id: "lovely-piano-song", title: "Lovely Piano Song", mood: "Chill"),
        Song(id: "nostalgic-piano", title: "Nostalgic Piano", mood: "Chill"),
        Song(id: "pina-colada", title: "Pina Colada", mood: "Chill"),
        Song(id: "shining-stars", title: "Shining Stars", mood: "Chill"),
        Song(id: "slice-of-life", title: "Slice of Life", mood: "Chill"),
        Song(id: "travelers-notebook", title: "Travelers Notebook", mood: "Chill"),
        Song(id: "sunny-rasta", title: "Sunny Rasta", mood: "Chill"),
        Song(id: "be-jammin", title: "Be Jammin", mood: "Chill"),
        Song(id: "going-bananas", title: "Going Bananas", mood: "Funny"),
        Song(id: "wakka-wakka", title: "Wakka Wakka", mood: "Funny"),
        Song(id: "silly-boy", title: "Silly Boy", mood: "Funny"),
        Song(id: "llama-in-pajama", title: "Llama in Pajama", mood: "Funny"),
        Song(id: "spring-chicken", title: "Spring Chicken", mood: "Funny"),
        Song(id: "busybody", title: "Busybody", mood: "Funny"),
        Song(id: "vintage-party", title: "Vintage Party", mood: "Funny"),
        Song(id: "le-baguette", title: "Le Baguette", mood: "Funny"),
        Song(id: "2-hour-delay", title: "2 Hour Delay", mood: "Lofi"),
        Song(id: "winter-blues", title: "Winter Blues", mood: "Lofi"),
        Song(id: "first-snow", title: "First Snow", mood: "Lofi"),
        Song(id: "snow-drift", title: "Snow Drift", mood: "Lofi"),
        Song(id: "fire-place", title: "Fire Place", mood: "Lofi"),
        Song(id: "kids", title: "Kids", mood: "Lofi"),
        Song(id: "spring-at-last", title: "Spring At Last", mood: "Lofi"),
        Song(id: "sense-of-purpose", title: "Sense Of Purpose", mood: "Lofi"),
        Song(id: "april-showers", title: "April Showers", mood: "Lofi"),
        Song(id: "deja-vu", title: "Deja Vu", mood: "Lofi"),
        Song(id: "boredom", title: "Boredom", mood: "Lofi"),
        Song(id: "anxiety", title: "Anxiety", mood: "Lofi"),
        Song(id: "love", title: "Love", mood: "Lofi"),
        Song(id: "old-age", title: "Old Age", mood: "Lofi"),
        Song(id: "dreams", title: "Dreams", mood: "Lofi"),
        Song(id: "chill-lofi-inspired", title: "Chill Lofi Inspired", mood: "Lofi"),
        Song(id: "lofi-hip-hop", title: "Lofi Hip Hop", mood: "Lofi"),
        Song(id: "japanese-lofi-hip-hop", title: "Japanese Lofi Hip Hop", mood: "Lofi"),
        Song(id: "since-2-am", title: "Since 2 AM", mood: "Lofi"),
        Song(id: "happy-lofi-day", title: "Happy Lofi Day", mood: "Lofi"),
        Song(id: "midsummer", title: "Midsummer", mood: "Lofi"),
        Song(id: "metaltania", title: "Metaltania", mood: "Metal"),
        Song(id: "dark-rock", title: "Dark Rock", mood: "Metal"),
        Song(id: "megasong", title: "Megasong", mood: "Metal"),
        Song(id: "metal-song-energetic", title: "Metal Song Energetic", mood: "Metal"),
        Song(id: "untitled-metal-track", title: "Untitled Metal Track", mood: "Metal"),
        Song(id: "heavy-dungeon", title: "Heavy Dungeon", mood: "Metal"),
        Song(id: "silver-bullet", title: "Silver Bullet", mood: "Metal"),
        Song(id: "boss-battle-8-metal", title: "Boss Battle 8 Metal", mood: "Metal"),
        Song(id: "once-more", title: "Once More", mood: "Metal"),
        Song(id: "fight-for-better-future", title: "Fight for Better Future", mood: "Metal"),
        Song(id: "unholy-surge", title: "Unholy Surge", mood: "Metal"),
        Song(id: "realm-of-torment", title: "Realm of Torment", mood: "Metal"),
        Song(id: "shadows-awaken-within", title: "Shadows Awaken Within", mood: "Metal"),
        Song(id: "dark-rising-guitar", title: "Dark Rising Guitar", mood: "Metal"),
        Song(id: "heavy-battle-1", title: "Heavy Battle 1", mood: "Metal"),
        Song(id: "drum-n-bass-e-energy", title: "Drum n Bass E Energy", mood: "Hardcore"),
        Song(id: "drum-n-bass-j-hit-me", title: "Drum n Bass J Hit Me", mood: "Hardcore"),
        Song(id: "drum-n-bass-k-megatrack", title: "Drum n Bass K Megatrack", mood: "Hardcore"),
        Song(id: "trance-a-metal-rush", title: "Trance A Metal Rush", mood: "Hardcore"),
        Song(id: "house-b-hard-off", title: "House B Hard Off", mood: "Hardcore"),
        Song(id: "punk-hardcore", title: "Punk Hardcore", mood: "Hardcore"),
        Song(id: "hardstyler", title: "Hardstyler", mood: "Hardcore"),
        Song(id: "bouncer", title: "Bouncer", mood: "Hardcore"),
        Song(id: "punk-rock-metal", title: "Punk Rock Metal", mood: "Hardcore"),
        Song(id: "hard-boss-battle-1", title: "Hard Boss Battle 1", mood: "Hardcore"),
        Song(id: "hard-battle-1", title: "Hard Battle 1", mood: "Hardcore"),
        Song(id: "fast-cheerful-punk-rock", title: "Fast Cheerful Punk Rock", mood: "Hardcore"),
    ]

    /// A post's song, if it has one (a song this build doesn't list still plays, from its id).
    /// How loud a post's song and its video's own sound are to be, each from 0 to 1 (both full unless the poster set them).
    static func mix(_ post: JSON) -> (song: Float, clip: Float) {
        let m = dict(dict(post["extra"])["mix"])
        return (Float(min(1, max(0, num(m["song"]) ?? 1))), Float(min(1, max(0, num(m["clip"]) ?? 1))))
    }

    static func of(_ post: JSON) -> Song? {
        let s = dict(dict(post["extra"])["song"]), id = str(s["id"])
        guard !id.isEmpty else { return nil }
        var song = all.first { $0.id == id } ?? Song(id: id, title: str(s["title"]), mood: "")
        song.start = num(s["start"])
        return song
    }
}

/// One song at a time, started by a tap: in the picker to hear it, on a post to play it. It stops at its end.
@Observable final class SongPlayer {
    static let shared = SongPlayer()
    /// What's playing: the song where it was started ("post:<id>", "pick:<id>").
    private(set) var playing: String?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var end: NSObjectProtocol?
    @ObservationIgnored private var edge: Any?    // watches for the end of the part that plays
    @ObservationIgnored private var base = 0.0    // where in the file that part starts
    @ObservationIgnored private var span = 0.0    // how long it is (0: the whole file)

    func toggle(_ song: Song, key: String) { if playing == key { stop() } else { play(song, key: key) } }

    /// Once a speaker on a post has been tapped on, songs start by themselves as their posts come up the feed, as
    /// Instagram's do, until one's tapped off again. Quiet until that first tap, so the feed never makes a sound
    /// nobody asked for. Until the app's closed (CheatDaysApp clears it at launch, as Instagram does).
    var auto: Bool {
        get { UserDefaults.standard.object(forKey: "song.auto") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "song.auto") }
    }
    /// Sound turned off on purpose, anywhere (a post's speaker, a video, a story's song): every song stays quiet until
    /// it's turned on again, wherever that is (18 Nov: the feed, videos and stories each had their own say). Never
    /// chosen isn't off: stories and videos play, the feed waits for its first tap.
    var mutedByChoice: Bool { UserDefaults.standard.object(forKey: "song.auto") as? Bool == false }
    /// The post with a song that's mostly on the screen, whether or not it's playing: what the volume buttons start.
    @ObservationIgnored private var seen: (song: Song, key: String, volume: Float, inVideo: Bool)?

    /// The volume buttons were pressed (VolumeButtons) while sound was off: it comes on, everywhere, as on Instagram
    /// (19 Nov; off on posts is off on stories too, and the buttons were no way back). The post on screen plays and
    /// songs start by themselves from then on; a story or a video showing hears `.soundOn` and starts its own.
    func volumePressed() {
        if !auto {
            auto = true
            if let s = seen, playing != s.key { play(s.song, key: s.key, loop: true, volume: s.volume, inVideo: s.inVideo) }
        }
        // anything still quiet that's showing (a video without a song, a story, a reel) turns its sound on; one already
        // heard carries on as it is
        NotificationCenter.default.post(name: .soundOn, object: nil)
    }

    /// The speaker on a post, tapped.
    func flip(_ song: Song, key: String, volume: Float = 1, inVideo: Bool = false) {
        if playing == key { auto = false; stop() } else { auto = true; play(song, key: key, loop: true, volume: volume, inVideo: inVideo) }
    }
    /// The song that's playing, stopped where it is and carried on from there (a story held under a finger).
    func hold(_ on: Bool) { if on { player?.pause() } else { player?.play() } }

    /// The song that's playing, moved to this many seconds in: to keep it in step with a video that's been scrubbed
    /// or has gone round to its start again.
    func seek(_ seconds: Double) {
        guard let player else { return }
        let length = span > 0 ? span : (player.currentItem?.duration.seconds ?? 0)
        let to = length.isFinite && length > 0 ? seconds.truncatingRemainder(dividingBy: length) : seconds
        player.seek(to: CMTime(seconds: base + max(0, to), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The song that's playing, louder or quieter (a slider being moved while it's heard).
    func volume(_ v: Float) { player?.volume = v }
    /// A post with a song has come onto the screen. Nothing if songs are off, or if the phone's already playing
    /// something of its own (their music or a podcast isn't cut off by scrolling past a photo).
    func arrive(_ song: Song, key: String, volume: Float = 1, inVideo: Bool = false) {
        seen = (song, key, volume, inVideo)
        guard auto, playing != key, !AVAudioSession.sharedInstance().isOtherAudioPlaying else { return }
        // heard with the ringer off as well: kept to the ringer, a phone on silent (most are) never played one, and
        // it looked as though songs only played when their button was pressed. The speaker turns them all off.
        play(song, key: key, loop: true, volume: volume, inVideo: inVideo)
    }
    /// It's gone off the screen again.
    func leave(_ key: String) {
        if seen?.key == key { seen = nil }
        if playing == key { stop() }
    }

    /// `loop`: under a post or a video it goes round for as long as that's on screen; in a list of songs it's heard once.
    /// `inVideo`: the song's mixed into the post's video (see SongMix). Nothing more to play: it's marked as playing,
    /// which turns the video's own sound on, and the sound's let through with the ringer off as a song is.
    func play(_ song: Song, key: String, loop: Bool = false, volume: Float = 1, inVideo: Bool = false) {
        stop()
        if inVideo {
            Sound.on()
            carried = true; playing = key
            return
        }
        // from its longer clip when it has one: the part the poster chose, or the usual 30 seconds of it
        let long = Music.long[song.id]
        guard let url = long != nil ? song.longURL : song.url else { return }
        Sound.on()
        let from = long != nil ? song.from : 0
        base = from
        span = long.map { min(Song.part, $0.len - from) } ?? 0
        let item = AVPlayerItem(url: MediaCache.source(url))   // the copy on the phone once it has been heard (MediaCache)
        let p = AVPlayer(playerItem: item)
        if from > 0 { p.seek(to: CMTime(seconds: from, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        // the part's over (or the file is): round again from where it starts, or done
        let over: () -> Void = { [weak self, weak p] in
            guard let self, let p, self.player === p else { return }
            if loop { p.seek(to: CMTime(seconds: from, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); p.play() } else { self.stop() }
        }
        end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in over() }
        if span > 0 {
            edge = p.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: from + span, preferredTimescale: 600))], queue: .main) {
                DispatchQueue.main.async { over() }
            }
        }
        // straight in, as Instagram's are (19 Nov: side by side with theirs, the fades read as lag)
        p.volume = volume
        player = p; playing = key
        p.play()
    }

    /// Stopped at once; the phone's own sound comes back a moment later, unless another song or a video's sound
    /// starts first (scrolling from one post to the next no longer turns the phone's sound off and on in between).
    func stop() {
        guard player != nil || playing != nil else { return }
        let old = player
        if let edge { old?.removeTimeObserver(edge) }
        edge = nil; player = nil
        if let end { NotificationCenter.default.removeObserver(end) }
        end = nil; playing = nil
        carried = false
        old?.pause()
        // a video being edited still wants sound
        if !loud { Sound.off() }
    }
    /// What's playing is a song mixed into a video, not one of its own.
    @ObservationIgnored private var carried = false

    /// A video's being edited: its sound, and any song put on it, are heard whether or not the phone's on silent,
    /// until the editor's left. Without this the editor was silent on a phone with its ringer off (most are), and
    /// each time a song stopped the video's own sound was cut off with it.
    @ObservationIgnored private var loud = false
    func heard(_ on: Bool) {
        loud = on
        if on { Sound.on() } else if player == nil { Sound.off() }
    }
}

/// The phone's sound, switched on and off away from the screen (19 Nov). Each song that started or stopped switched
/// it on the main thread, which can hold everything up: side by side with Instagram, the feed stood still for 0.7 s
/// mid-scroll at the moment a post's song came in (the cause is the likeliest one, not proven). Off is put off for a
/// moment and called off by any sound wanted meanwhile, so moving between posts doesn't switch it off and on again.
/// Off is `.ambient`: muted videos then play alongside someone's own music instead of stopping it.
enum Sound {
    private static let q = DispatchQueue(label: "cheatdays.sound", qos: .userInitiated)
    // only touched on q
    private static var ticket = 0

    /// Heard with the ringer off too (`.playback`).
    static func on(_ m: AVAudioSession.Mode = .default) {
        q.async {
            ticket += 1
            // read from the session itself, as other parts of the app (dictation) change it too
            let s = AVAudioSession.sharedInstance()
            if s.category != .playback || s.mode != m { try? s.setCategory(.playback, mode: m) }
            try? s.setActive(true)
        }
    }

    /// Back to the ringer and whatever else was playing, a moment from now unless sound's wanted again first.
    static func off(after: Double = 1) {
        q.async {
            ticket += 1
            let mine = ticket
            q.asyncAfter(deadline: .now() + after) {
                guard mine == ticket else { return }
                let s = AVAudioSession.sharedInstance()
                guard s.category == .playback else { return }   // already off, or another part of the app has it
                try? s.setActive(false, options: .notifyOthersOnDeactivation)
                try? s.setCategory(.ambient)
                // kept on, quietly, alongside anything else playing: the volume buttons are only heard while it is
                try? s.setActive(true)
            }
        }
    }

    /// At launch: on, quietly (`.ambient` plays alongside their own music and keeps to the ringer), so the volume
    /// buttons can be heard (VolumeButtons).
    static func ready() {
        q.async {
            let s = AVAudioSession.sharedInstance()
            // (26 Nov: a run's voice left ducking on is put back too, so their music isn't held lower)
            if s.category != .playback || s.categoryOptions.contains(.duckOthers) {
                if s.categoryOptions.contains(.duckOthers) { try? s.setActive(false, options: .notifyOthersOnDeactivation) }
                try? s.setCategory(.ambient)
            }
            try? s.setActive(true)
        }
    }
}

extension Notification.Name {
    /// Sound turned on with the volume buttons: whatever's showing starts its sound (SongPlayer.volumePressed).
    static let soundOn = Notification.Name("soundOn")
}

/// The volume buttons, pressed (19 Nov): as on Instagram, turning the volume up or down while sound's off turns it
/// on. Heard as a change in the phone's volume, so a press at the very top or bottom (nothing changes) isn't heard.
final class VolumeButtons {
    static let shared = VolumeButtons()
    private var watch: NSKeyValueObservation?
    private var back: NSObjectProtocol?
    func start() {
        guard watch == nil else { return }
        // back from another app, the phone may have let the app's sound go: on again, quietly, to hear the buttons
        back = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            if SongPlayer.shared.playing == nil { Sound.ready() }
        }
        watch = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.old, .new]) { _, change in
            guard let was = change.oldValue, let now = change.newValue, abs(was - now) > 0.001 else { return }
            DispatchQueue.main.async { SongPlayer.shared.volumePressed() }
        }
    }
}

/// The songs by mood: play one to hear it, Add to put it on the post.
struct SongPicker: View {
    var pick: (Song) -> Void
    @Environment(\.dismiss) private var dismiss
    private var player: SongPlayer { SongPlayer.shared }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Music.moods, id: \.self) { mood in
                    Section(mood) {
                        ForEach(Music.all.filter { $0.mood == mood }) { s in
                            let on = player.playing == "pick:" + s.id
                            HStack(spacing: 12) {
                                Button { player.toggle(s, key: "pick:" + s.id) } label: {
                                    Image(systemName: on ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                                        .frame(width: 36, height: 36).background(Color(.tertiarySystemFill), in: Circle())
                                }
                                .buttonStyle(.borderless).accessibilityLabel(on ? "Stop \(s.title)" : "Play \(s.title)")
                                Text(s.title).font(.body.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                                Button("Add") { player.stop(); pick(s); dismiss() }.font(.subheadline.weight(.bold)).buttonStyle(.borderless)
                                    .accessibilityLabel("Add \(s.title)")
                            }
                        }
                    }
                }
                Section { } footer: { Text("Free-to-use music released as public domain (CC0), from FreePD, HoliznaCC0 and OpenGameArt. About 30 seconds of each plays on a post.") }
            }
            .navigationTitle("Add a song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { player.stop(); dismiss() } } }
            .onDisappear { player.stop() }
        }
    }
}

/// Which part of a song plays: the whole of its longer clip as a strip of its sound, and a window on it, as long as
/// the part that plays, slid to where it should start. Nothing for a song with no longer clip to choose from.
struct SongScrub: View {
    @Binding var song: Song
    /// The window's been let go: play it from there.
    var moved: (Song) -> Void
    /// Where the window is while it's under a finger. Kept here until it's let go, so the screen it sits on (the
    /// editor's a big one) isn't worked out again for every step of the drag.
    @State private var dragged: Double?

    var body: some View {
        if let long = Music.long[song.id], long.len > Song.part + 2 {
            let from = dragged ?? song.from, levels = Array(long.wave)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Part of the song").font(.caption2.weight(.bold)).textCase(.uppercase).tracking(0.6).opacity(0.6)
                    Spacer()
                    Text("\(Self.clock(from)) – \(Self.clock(from + Song.part))").font(.caption.weight(.semibold)).monospacedDigit()
                }
                GeometryReader { g in
                    let w = g.size.width, win = w * Song.part / long.len, x = w * from / long.len
                    ZStack(alignment: .leading) {
                        HStack(alignment: .center, spacing: 1.5) {
                            ForEach(levels.indices, id: \.self) { i in
                                let at = (Double(i) + 0.5) / Double(levels.count) * long.len
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .fill(at >= from && at < from + Song.part ? Theme.accent : Color.primary.opacity(0.28))
                                    .frame(height: 6 + CGFloat(levels[i].wholeNumberValue ?? 0) * 3.4)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary, lineWidth: 2.5)
                            .frame(width: win, height: 46).offset(x: x)
                    }
                    .frame(height: 46).contentShape(Rectangle())
                    // the window's middle follows the finger, kept inside the strip
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { v in
                            let s = Double((v.location.x - win / 2) / max(w, 1)) * long.len
                            dragged = (min(max(0, s), long.len - Song.part) * 10).rounded() / 10
                        }
                        .onEnded { _ in
                            var now = song
                            if let d = dragged { now.start = d }
                            song = now; dragged = nil
                            UISelectionFeedbackGenerator().selectionChanged(); moved(now)
                        })
                }
                .frame(height: 46)
                .accessibilityElement().accessibilityLabel("Part of the song").accessibilityValue("From \(Self.clock(from))")
                .accessibilityAdjustableAction { way in
                    let s = from + (way == .increment ? 5 : -5)
                    var now = song
                    now.start = min(max(0, s), long.len - Song.part)
                    song = now; moved(now)
                }
                HStack { Text("0:00"); Spacer(); Text(Self.clock(long.len)) }.font(.caption2).monospacedDigit().opacity(0.5)
            }
        }
    }

    static func clock(_ seconds: Double) -> String {
        let t = Int(seconds.rounded())
        return "\(t / 60):" + (t % 60 < 10 ? "0" : "") + "\(t % 60)"
    }
}
