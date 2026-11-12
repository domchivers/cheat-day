import AVFoundation
import SwiftUI

/// A song people can add to a post: a 30-second clip, streamed.
struct Song: Identifiable, Hashable {
    let id: String, title: String, mood: String
    var url: URL? { URL(string: Music.base + id + ".m4a") }
}

/// The songs for posts. Every one is from FreePD's public-domain (CC0) collection, cut to 30 seconds by
/// design/music_clips.py; the clips and the record of where each came from are in music/ at the top of the repo,
/// which the site's GitHub Pages serves. A post carries its song as extra.song {id, title}.
enum Music {
    static let base = "https://domchivers.github.io/cheat-day/music/"
    static let moods = ["Upbeat", "Gym", "Epic", "Chill", "Funny"]
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
    ]

    /// A post's song, if it has one (a song this build doesn't list still plays, from its id).
    static func of(_ post: JSON) -> Song? {
        let s = dict(dict(post["extra"])["song"]), id = str(s["id"])
        guard !id.isEmpty else { return nil }
        return all.first { $0.id == id } ?? Song(id: id, title: str(s["title"]), mood: "")
    }
}

/// One song at a time, started by a tap: in the picker to hear it, on a post to play it. It stops at its end.
@Observable final class SongPlayer {
    static let shared = SongPlayer()
    /// What's playing: the song where it was started ("post:<id>", "pick:<id>").
    private(set) var playing: String?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var end: NSObjectProtocol?

    func toggle(_ song: Song, key: String) { if playing == key { stop() } else { play(song, key: key) } }

    /// Once a speaker on a post has been tapped on, songs start by themselves as their posts come up the feed, as
    /// Instagram's do, until one's tapped off again. Quiet until that first tap, so the feed never makes a sound
    /// nobody asked for. Kept between launches.
    var auto: Bool {
        get { UserDefaults.standard.object(forKey: "song.auto") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "song.auto") }
    }
    /// The speaker on a post, tapped.
    func flip(_ song: Song, key: String) {
        if playing == key { auto = false; stop() } else { auto = true; play(song, key: key, loop: true) }
    }
    /// A post with a song has come onto the screen. Nothing if songs are off, or if the phone's already playing
    /// something of its own (their music or a podcast isn't cut off by scrolling past a photo).
    func arrive(_ song: Song, key: String) {
        guard auto, playing != key, !AVAudioSession.sharedInstance().isOtherAudioPlaying else { return }
        // heard with the ringer off as well: kept to the ringer, a phone on silent (most are) never played one, and
        // it looked as though songs only played when their button was pressed. The speaker turns them all off.
        play(song, key: key, loop: true)
    }
    /// It's gone off the screen again.
    func leave(_ key: String) { if playing == key { stop() } }

    /// `loop`: under a post or a video it goes round for as long as that's on screen; in a list of songs it's heard once.
    func play(_ song: Song, key: String, loop: Bool = false) {
        stop()
        guard let url = song.url else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        end = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak p] _ in
            if loop { p?.seek(to: .zero); p?.play() } else { self?.stop() }
        }
        player = p; playing = key
        p.play()
    }

    func stop() {
        guard player != nil || playing != nil else { return }
        player?.pause(); player = nil
        if let end { NotificationCenter.default.removeObserver(end) }
        end = nil; playing = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? AVAudioSession.sharedInstance().setCategory(.soloAmbient)
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
                Section { } footer: { Text("Free-to-use music from FreePD's public-domain collection. About 30 seconds of each plays on a post.") }
            }
            .navigationTitle("Add a song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { player.stop(); dismiss() } } }
            .onDisappear { player.stop() }
        }
    }
}
