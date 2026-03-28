import SwiftUI
import AVFoundation

// MARK: - SplashView

/// Full-screen video splash shown once per launch, immediately after the
/// iOS LaunchScreen. Uses AVPlayer so the video can be detected as complete
/// rather than relying on a hardcoded timer.
///
/// Integration: overlay this on top of RootView with a high zIndex.
/// Call `onComplete` to fade it out — transition is handled by the caller.
struct SplashView: UIViewRepresentable {
    let onComplete: () -> Void

    func makeUIView(context: Context) -> SplashPlayerView {
        let view = SplashPlayerView()
        view.backgroundColor = .white
        view.onComplete = onComplete
        view.play()
        return view
    }

    func updateUIView(_ uiView: SplashPlayerView, context: Context) {}
}

// MARK: - SplashPlayerView

/// UIView subclass that owns the AVPlayer and AVPlayerLayer.
/// Kept as a UIView (not UIViewController) so it embeds cleanly
/// into UIViewRepresentable without lifecycle complications.
final class SplashPlayerView: UIView {

    var onComplete: (() -> Void)?

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var endObserver: Any?

    // Keep layer frame in sync with Auto Layout bounds changes.
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }

    func play() {
        guard let url = Bundle.main.url(forResource: "splash", withExtension: "mp4") else {
            // Video missing from bundle — skip splash immediately.
            onComplete?()
            return
        }

        let item   = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.addSublayer(layer)

        self.player      = player
        self.playerLayer = layer

        // Detect natural end of playback — no hardcoded delay.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onComplete?()
        }

        player.play()
    }

    deinit {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }
}
