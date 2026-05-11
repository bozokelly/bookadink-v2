import Foundation
import CoreLocation
import MapKit

/// Resolves driving distance + ETA between two coordinates via MapKit's
/// `MKDirections.calculateETA()`. Results are cached in memory by a coarse
/// origin grid (~500 m) and finer destination grid (~50 m) so small user
/// movements and co-located venues share cache entries.
///
/// Used by Explore Nearby to upgrade the haversine distance label to a real
/// driving distance + ETA once available. Failures are silent — the caller
/// keeps its haversine fallback. Concurrency is capped to keep MapKit happy
/// when a long list of rows requests at once.
///
/// ## Cache scope: session-only
/// Cache lives on this actor singleton in memory and is intentionally NOT
/// persisted (no `UserDefaults`, no disk, no Supabase). Rationale:
///
/// - MapKit ETAs fold in time-of-day + traffic assumptions and go stale fast.
/// - A wrong cached drive time across a relaunch reads worse than the
///   haversine fallback would.
/// - Resolution is cheap, lazy, and fails safely, so re-resolving after a
///   relaunch is acceptable.
///
/// Expected behaviour:
/// - Navigate away from Explore Nearby and back without killing the app →
///   cached ETA labels reappear immediately.
/// - Force-kill / relaunch → cache is reset. Haversine labels render
///   instantly; driving ETAs resolve again lazily for visible rows.
/// - 24 h TTL (`CachedETA.isFresh`) caps freshness within a single session.
actor DrivingETAService {
    static let shared = DrivingETAService()

    struct CachedETA {
        let distanceMeters: Double
        let travelTimeSeconds: TimeInterval
        let createdAt: Date

        var isFresh: Bool {
            Date().timeIntervalSince(createdAt) < 24 * 3_600
        }

        /// Display string in the form `"32 km · ~38 min drive"`.
        /// Sub-10 km values keep one decimal so the value reads useful at short range.
        var displayLabel: String {
            let km = distanceMeters / 1_000
            let kmStr = km < 10
                ? String(format: "%.1f km", km)
                : "\(Int(km.rounded())) km"
            let minutes = max(1, Int((travelTimeSeconds / 60).rounded()))
            return "\(kmStr) · ~\(minutes) min drive"
        }
    }

    private struct CacheKey: Hashable {
        let userLatBucket: Int
        let userLonBucket: Int
        let destLatBucket: Int
        let destLonBucket: Int
    }

    private var cache: [CacheKey: CachedETA] = [:]
    private var inFlight: [CacheKey: Task<CachedETA?, Never>] = [:]

    // Concurrency limiter — keeps in-flight MKDirections calls below a polite
    // ceiling so a freshly opened 50-card list does not trip Apple's per-app
    // rate limiter. Continuation-based so waiters wake in FIFO order.
    private let maxConcurrent: Int = 2
    private var activeCount: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func bucketKey(from user: CLLocationCoordinate2D, to dest: CLLocationCoordinate2D) -> CacheKey {
        // 1° latitude ≈ 111 km. 500 m ≈ 0.0045° → factor ≈ 222.
        // 50 m ≈ 0.00045° → factor ≈ 2 222. Same factor for lon — bucketing only.
        CacheKey(
            userLatBucket: Int((user.latitude * 222).rounded()),
            userLonBucket: Int((user.longitude * 222).rounded()),
            destLatBucket: Int((dest.latitude * 2_222).rounded()),
            destLonBucket: Int((dest.longitude * 2_222).rounded())
        )
    }

    /// Resolves an ETA, returning the cached value when fresh and otherwise
    /// calling `MKDirections.calculateETA()`. Returns nil on failure or
    /// MapKit error — the caller should keep its fallback label.
    /// Concurrent callers for the same bucket coalesce onto a single request.
    func resolveETA(from user: CLLocationCoordinate2D, to dest: CLLocationCoordinate2D) async -> CachedETA? {
        let key = bucketKey(from: user, to: dest)

        if let value = cache[key], value.isFresh { return value }
        if let pending = inFlight[key] { return await pending.value }

        let task = Task<CachedETA?, Never> { [weak self] in
            guard let self else { return nil }
            await self.acquireSlot()
            defer { Task { await self.releaseSlot() } }

            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: user))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
            request.transportType = .automobile

            do {
                let response = try await MKDirections(request: request).calculateETA()
                return CachedETA(
                    distanceMeters: response.distance,
                    travelTimeSeconds: response.expectedTravelTime,
                    createdAt: Date()
                )
            } catch {
                return nil
            }
        }
        inFlight[key] = task

        let result = await task.value
        inFlight[key] = nil
        if let result {
            cache[key] = result
        }
        return result
    }

    // MARK: - Concurrency limiter

    private func acquireSlot() async {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        // On resume, the slot was handed off from releaseSlot — activeCount unchanged.
    }

    private func releaseSlot() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
            // Slot transferred; activeCount unchanged.
        } else {
            activeCount -= 1
        }
    }
}
