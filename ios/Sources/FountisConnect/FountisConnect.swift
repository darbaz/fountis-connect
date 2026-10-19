import Foundation
import UIKit
import UserNotifications

/// FOUNTIS Connect for iOS.
///
/// Guests: when the token provider returns `nil` (nobody is signed in) and FOUNTIS has switched guests on
/// for your app, the SDK offers the free studies marked open to guests, after an 18+ confirmation. Nothing
/// to call; an app without accounts can pass `setUserToken { nil }`.
///
/// ```swift
/// // At launch (App.init or application(_:didFinishLaunchingWithOptions:)), not in a view:
/// FountisConnect.start(key: "pk_live_...")
/// FountisConnect.setUserToken { try await myServer.fountisToken() }   // nil when signed out
/// FountisConnect.enableNotifications()                                // optional
/// ```
///
/// Background refresh needs `BGTaskSchedulerPermittedIdentifiers` = `org.fountis.connect.refresh` and
/// the `fetch` background mode in Info.plist, and `start` must run before the app finishes launching.
@MainActor
public enum FountisConnect {
    /// Production base URL until `api.fountis.org` is live.
    public static let defaultAPIBase = URL(string: "https://ucclsekjekdxzfwzyuji.supabase.co/functions/v1/connect-api/v1")!

    /// Starts the SDK. Call once, at launch, before the app finishes launching (it registers the background refresh task).
    public static func start(key: String, apiBase: URL? = nil) {
        Core.shared.start(key: key, apiBase: apiBase ?? defaultAPIBase)
    }

    /// Gives the SDK a way to get the signed user token from your server. Return `nil` only when nobody is signed in.
    /// Throw when you cannot get a token (offline, server error): the SDK shows nothing and treats it as `noFill`, never as a guest.
    /// A provider that does not answer within 10 seconds counts as a failure the same way, and an empty string is not "signed out".
    /// Called on demand, never cached by the SDK for longer than one check.
    public static func setUserToken(_ provider: @escaping () async throws -> String?) {
        Core.shared.setUserToken(provider)
    }

    /// Asks for notification permission and starts the background check. One local notification a day at most.
    public static func enableNotifications() { Core.shared.enableNotifications() }

    /// Looks for a matching study and shows it as a sheet. Returns `.noFill` fast when there is nothing to show.
    @discardableResult
    public static func show() async -> FountisResult { await Core.shared.run(mode: .manual) }

    /// Call from your push handler with the payload. Returns `true` if it is a FOUNTIS push (it carries a `fountis` key).
    @discardableResult
    public static func handlePush(_ userInfo: [AnyHashable: Any]) -> Bool { Core.shared.handlePush(userInfo) }

    /// For apps with their own `UNUserNotificationCenterDelegate`: call from `didReceive response`.
    /// Returns `true` (and presents the study) if the notification was a FOUNTIS one.
    @discardableResult
    public static func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        Core.shared.handleNotificationUserInfo(response.notification.request.content.userInfo)
    }

    /// Pass the person's consent to be offered studies (for example from your own consent screen). Default: `true`.
    public static func setUserConsent(_ granted: Bool) { Core.shared.consent = granted }

    /// Forget the signed-in person: removes this person's local state and pending notifications.
    public static func signOut() { Core.shared.signOut() }

    /// Anonymous lifecycle events (`shown`, `dismissed`, `completed`, `noFill`, `notified`).
    public static func onEvent(_ listener: @escaping (FountisEvent) -> Void) { Core.shared.listeners.append(listener) }
}

// MARK: - Core

@MainActor
final class Core {
    static let shared = Core()

    enum Mode { case manual, auto, offer(String) }

    var consent = true
    var listeners: [(FountisEvent) -> Void] = []

    private var api: ApiClient?
    private var provider: (() async throws -> String?)?
    private var started = false
    private var presenting = false
    private var autoShownThisSession = false
    private var skippedWhileInactive = false
    private var autoTask: Task<Void, Never>?
    private var backgroundedAt: Date?
    private var cache: (lang: String, at: Date, value: SurveysResponse)?
    private var notificationsOn: Bool
    private var forwardingDelegate: ForwardingNotificationDelegate?
    private var lastSubHash: String?
    private var guestSession: (token: String, expires: Date)?
    /// Device attestation for guest sessions (only used when the app's `app.attest.mode` is `report` or `enforce`).
    private let guestSessions = GuestSessionMaker(attestor: Attestor())
    private let accentHex = "#5dc0a0"

    private init() {
        notificationsOn = UserDefaults(suiteName: "org.fountis.connect.state")?.bool(forKey: "notifications") ?? false
    }

    // MARK: setup

    func start(key: String, apiBase: URL) {
        guard !started else { return }
        guard key.hasPrefix("pk_") else { fcLog.debug("start: key must be a publishable key (pk_...)"); return }
        started = true
        api = ApiClient(base: apiBase, key: key)
        _ = BGRefresh.register { [weak self] in await self?.checkAndNotify() }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didBecomeActive() }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.backgroundedAt = Date() }
        }
        if notificationsOn { BGRefresh.schedule(minutes: nil) }
        if UIApplication.shared.applicationState == .active { scheduleAutoShow() }
    }

    func setUserToken(_ p: @escaping () async throws -> String?) {
        provider = p
        if started, UIApplication.shared.applicationState == .active { scheduleAutoShow() }
    }

    func enableNotifications() {
        notificationsOn = true
        UserDefaults(suiteName: "org.fountis.connect.state")?.set(true, forKey: "notifications")
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil {
            let d = ForwardingNotificationDelegate()
            forwardingDelegate = d
            center.delegate = d
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in fcLog.debug("notification permission: \(granted)") }
        BGRefresh.schedule(minutes: cache?.value.config?.checkIntervalMinutes)
    }

    func signOut() {
        autoTask?.cancel()
        if let h = lastSubHash { LocalState(subHash: h).clear() }
        lastSubHash = nil
        guestSession = nil
        cache = nil
        autoShownThisSession = false
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    // MARK: foreground / push / notification tap

    private func didBecomeActive() {
        if let b = backgroundedAt, Date().timeIntervalSince(b) > 1800 { autoShownThisSession = false }
        backgroundedAt = nil
        scheduleAutoShow()
    }

    private func scheduleAutoShow() {
        guard !autoShownThisSession, provider != nil else { return }
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000) // let the host UI settle
            guard let self, !Task.isCancelled, !self.autoShownThisSession else { return }
            // A system alert (the notification permission prompt on first launch) makes the app inactive. Do not
            // spend the session's one auto-show on that: didBecomeActive schedules it again once the alert is gone.
            guard UIApplication.shared.applicationState == .active else { return }
            self.autoShownThisSession = true
            self.skippedWhileInactive = false
            let result = await self.run(mode: .auto)
            // The alert can also appear while the request is in flight; run() then refuses to present. Give the auto-show back.
            if result == .noFill, self.skippedWhileInactive {
                self.autoShownThisSession = false
                if UIApplication.shared.applicationState == .active { self.scheduleAutoShow() }
            }
        }
    }

    func handlePush(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo["fountis"] != nil else { return false }
        Task { [weak self] in
            guard let self else { return }
            if UIApplication.shared.applicationState == .active { _ = await self.run(mode: .auto) } else { await self.checkAndNotify() }
        }
        return true
    }

    func handleNotificationUserInfo(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let offerId = userInfo["fountis"] as? String else { return false }
        Task { [weak self] in
            guard let self else { return }
            // cold start: wait (briefly) for the app to be active with a window to present from
            for _ in 0..<20 where UIApplication.shared.applicationState != .active || Presenter.topViewController() == nil {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            self.autoShownThisSession = true
            _ = await self.run(mode: .offer(offerId))
        }
        return true
    }

    // MARK: data

    private func fetchSurveys(api: ApiClient, lang: String) async throws -> SurveysResponse {
        if let c = cache, c.lang == lang, Date().timeIntervalSince(c.at) < 60 { return c.value }
        let r = try await api.surveys(lang: lang)
        cache = (lang, Date(), r)
        return r
    }

    private func emit(_ type: String, _ offerId: String? = nil) {
        let e = FountisEvent(type: type, offerId: offerId)
        listeners.forEach { $0(e) }
    }

    private struct Session {
        let api: ApiClient
        /// Signed user token; nil for a guest.
        let token: String?
        let info: TokenInfo?
        let lang: String
        let surveys: SurveysResponse
        let state: LocalState

        var isGuest: Bool { token == nil }

        func matches(_ offer: Offer) -> Bool {
            if let info { return Matcher.matches(offer, token: info) }
            return Matcher.matchesGuest(offer)
        }
    }

    /// A guest session token, kept in memory for most of its hour. `force` makes a new one.
    /// A new one is attested when the app asks for it (`app.attest.mode`); with mode `off` or absent attestation is never touched.
    private func guestToken(_ s: Session, force: Bool = false) async throws -> String {
        if !force, let g = guestSession, g.expires > Date() { return g.token }
        let t = try await guestSessions.make(api: s.api, mode: s.surveys.app?.attestMode ?? .off, installId: GuestInstall.id())
        guestSession = (t, Date().addingTimeInterval(55 * 60))
        return t
    }

    private func openSession() async -> Session? {
        guard started, consent, let api, let provider else { return nil }
        do {
            // Only nil means signed out (the guest path). A throw or a provider that stays silent past the timeout is a failed check.
            guard let token = try await callTokenProvider(provider) else { return await openGuestSession(api: api) }
            // An empty string is an unusable token, not "signed out": noFill, never a guest.
            guard !token.isEmpty, let info = TokenInfo.decode(token) else { return nil }
            if let exp = info.exp, exp < Date().timeIntervalSince1970 { return nil }
            lastSubHash = info.subHash
            let lang = info.lang.map(Strings.normalize) ?? Strings.deviceLang
            let surveys = try await fetchSurveys(api: api, lang: lang)
            return Session(api: api, token: token, info: info, lang: lang, surveys: surveys, state: LocalState(subHash: info.subHash))
        } catch is TokenProviderTimeout {
            fcLog.debug("check failed: the token provider did not answer within \(Int(tokenProviderTimeout)) seconds")
            return nil
        } catch {
            fcLog.debug("check failed: \(String(describing: error))")
            return nil
        }
    }

    /// Nobody is signed in: a guest session, only when the app allows guests.
    private func openGuestSession(api: ApiClient) async -> Session? {
        do {
            let lang = Strings.deviceLang
            let surveys = try await fetchSurveys(api: api, lang: lang)
            guard surveys.app?.guests == true, surveys.surveys.contains(where: { $0.guest == true }) else { return nil }
            lastSubHash = "guest"
            return Session(api: api, token: nil, info: nil, lang: lang, surveys: surveys, state: LocalState(subHash: "guest"))
        } catch {
            fcLog.debug("guest check failed: \(String(describing: error))")
            return nil
        }
    }

    /// Starts the attempt for a person with a token or a guest session (a stale guest session is renewed once).
    private func createAttempt(_ s: Session, offerId: String) async throws -> [String: Any] {
        if let token = s.token { return try await s.api.createAttempt(offerId: offerId, token: token, lang: s.lang) }
        let session = try await guestToken(s)
        do {
            return try await s.api.createGuestAttempt(offerId: offerId, guestSession: session, lang: s.lang)
        } catch let e as APIError where e.code == "invalid_session" {
            let fresh = try await guestToken(s, force: true)
            return try await s.api.createGuestAttempt(offerId: offerId, guestSession: fresh, lang: s.lang)
        }
    }

    // MARK: show

    func run(mode: Mode) async -> FountisResult {
        let result = await runInner(mode: mode)
        if result == .noFill { emit("noFill") }
        return result
    }

    private func runInner(mode: Mode) async -> FountisResult {
        guard !presenting else { return .noFill }
        presenting = true
        defer { presenting = false }

        guard let s = await openSession() else { return .noFill }
        guard UIApplication.shared.applicationState == .active, Presenter.topViewController() != nil else {
            skippedWhileInactive = true
            return .noFill
        }

        var offers = s.surveys.surveys.filter { s.matches($0) }
        switch mode {
        case .manual: offers = offers.filter { !s.state.isTaken($0.offerId) }
        case .auto: offers = offers.filter { !s.state.isSuppressedForAutoShow($0.offerId) }
        case .offer(let id): offers = offers.filter { $0.offerId == id && !s.state.isTaken($0.offerId) }
        }
        // Rewarded first, then shortest.
        offers.sort { (($0.reward?.isRewarded ?? false) && !($1.reward?.isRewarded ?? false)) }

        for offer in offers.prefix(3) {
            do {
                let a = try await createAttempt(s, offerId: offer.offerId)
                return await present(offer: offer, attempt: a, session: s)
            } catch let e as APIError {
                if e.code == "already_taken" { s.state.markTaken(offer.offerId) }
                // The app enforces attestation and this device has none that passes: no guest offers this time, no retry.
                if e.isAttestationRefusal { fcLog.debug("guest studies not offered: \(e.code)"); return .noFill }
                if e.skipsToNextOffer { continue }
                fcLog.debug("attempt failed: \(e.code)")
                return .noFill
            } catch {
                fcLog.debug("attempt failed: \(String(describing: error))")
                return .noFill
            }
        }
        return .noFill
    }

    private func present(offer: Offer, attempt a: [String: Any], session s: Session) async -> FountisResult {
        guard let attemptToken = a["attempt_token"] as? String, a["definition"] != nil,
              let engineURL = Bundle.module.url(forResource: "engine", withExtension: "html", subdirectory: "Engine"),
              let top = Presenter.topViewController() else { return .noFill }

        var payload: [String: Any] = [
            "mode": "native",
            "definition": a["definition"] ?? NSNull(),
            "answers": a["answers"] ?? [String: Any](),
            "lang": s.lang,
            "rtl": Strings.isRTL(s.lang),
            "theme": ["accent": accentHex],
            "consentNeeded": (a["consent_needed"] as? Bool) ?? false,
            "attrs": s.info?.carriedAttrs ?? [],
        ]
        if s.isGuest || (a["guest"] as? Bool) == true { payload["guest"] = true }
        if let name = s.surveys.app?.name { payload["partner"] = name }
        if let rid = a["rid"] as? String { payload["rid"] = rid }
        if let r = a["reward"] as? [String: Any], ((r["units"] as? NSNumber)?.intValue ?? 0) > 0 {
            payload["reward"] = ["units": r["units"] ?? 0, "unit_name": r["unit_name"] ?? ""]
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<FountisResult, Never>) in
            let sheet = SheetController(engineURL: engineURL, initPayload: payload, api: s.api, attemptToken: attemptToken, onShown: { [weak self] in
                self?.emit("shown", offer.offerId)
                Task { await s.api.event(offerId: offer.offerId, type: "shown") }
            }) { [weak self] fin in
                // UIKit never showed it: nothing happened to the offer, so no taken/dismissed mark, no event.
                if fin.unavailable { cont.resume(returning: .noFill); return }
                let result: FountisResult
                if fin.outcome == "complete" {
                    result = .completed
                    s.state.markTaken(offer.offerId)
                    self?.emit("completed", offer.offerId)
                } else {
                    result = .dismissed
                    if fin.outcome == "screen_out" || fin.fatal == "already_taken" { s.state.markTaken(offer.offerId) } else { s.state.markDismissed(offer.offerId) }
                    self?.emit("dismissed", offer.offerId)
                    Task { await s.api.event(offerId: offer.offerId, type: "dismissed") }
                }
                cont.resume(returning: result)
            }
            guard !top.isBeingDismissed else { cont.resume(returning: .noFill); return }
            Presenter.present(sheet, on: top)
        }
    }

    // MARK: notifications

    /// Background / push check: at most one local notification a day, never in quiet hours.
    func checkAndNotify() async {
        guard notificationsOn, let s = await openSession() else { return }
        let cfg = s.surveys.config
        BGRefresh.schedule(minutes: cfg?.checkIntervalMinutes)
        guard UIApplication.shared.applicationState != .active else { return } // foreground uses auto-show
        guard !Matcher.inQuietHours(cfg?.quietHours), s.state.notificationsToday < min(max(cfg?.maxNotificationsPerDay ?? 1, 0), 1) else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        guard let offer = s.surveys.surveys.first(where: { s.matches($0) && !s.state.isSuppressedForNotification($0.offerId) }) else { return }

        let content = UNMutableNotificationContent()
        content.title = Strings.get("connect.notify.title", lang: s.lang)
        let minutes = String(max(offer.loiMinutes ?? 5, 1))
        if let r = offer.reward, r.isRewarded {
            content.body = Strings.get("connect.notify.bodyReward", lang: s.lang, ["minutes": minutes, "units": String(r.units ?? 0), "unit": r.unitLabel(lang: s.lang)])
        } else {
            content.body = Strings.get("connect.notify.body", lang: s.lang, ["minutes": minutes])
        }
        content.sound = .default
        content.userInfo = ["fountis": offer.offerId]
        let req = UNNotificationRequest(identifier: "org.fountis.connect.\(offer.offerId)", content: content,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        do {
            try await UNUserNotificationCenter.current().add(req)
            s.state.markNotified(offer.offerId)
            emit("notified", offer.offerId)
        } catch { fcLog.debug("notification failed: \(error.localizedDescription)") }
    }
}

// MARK: - Presenter

/// How long UIKit may take to start showing the survey before `show()` gives up (`noFill`). Same 10 seconds as the Android SDK.
let sheetAppearTimeout: TimeInterval = 10

enum Presenter {
    /// Presents `sheet` on `top`, and abandons it if UIKit has not started showing it within `timeout` seconds.
    /// A presentation UIKit refuses (for example `top`'s view is not in a window) is only a console warning: no error,
    /// no completion, never retried. Without the watchdog the sheet would never finish, `Core.presenting` would stay
    /// set, and every later show would be `noFill`.
    @MainActor
    static func present(_ sheet: SheetController, on top: UIViewController, timeout: TimeInterval = sheetAppearTimeout) {
        top.present(sheet, animated: true)
        // The task holds the sheet: when UIKit refuses, nothing else does, and a sheet that deallocates drops its onFinish.
        Task {
            do { try await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000)) } catch { return }
            sheet.abandonIfNotShown()
        }
    }

    /// The top-most view controller of the foreground window scene, or nil if there is nowhere to present.
    @MainActor
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first { $0.activationState == .foregroundInactive }
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first else { return nil }
        var top = window.rootViewController
        while let p = top?.presentedViewController, !p.isBeingDismissed { top = p }
        if top is SheetController { return nil }
        return top
    }
}
