import Combine
import OSLog
import SwiftData
import SwiftUI
import GoldLifeUI
import GoldLifeID

@MainActor
final class UserDemoMode: ObservableObject {
    static let shared = UserDemoMode()

    private static let log = Logger(subsystem: "com.evolvedbygl.GLSmallBusiness",
                                    category: "SampleData")

    /// Mirrored into UserDefaults under the SAME key GateView's @AppStorage
    /// watches — that's what actually flips the gate. The @Published half keeps
    /// the banner and any plain observers live.
    @Published var isDemoActive: Bool = false
    /// Set when the sample container couldn't be built — the gate shows the
    /// alert half; the log line above is the developer half.
    @Published var seedError: String?
    var demoContainer: ModelContainer?

    /// mb-namespaced (law 26). The one-shot migration below keeps an in-progress
    /// sample session alive across the rename.
    static let defaultsKey = "mb.demoMode"
    private static let legacyDefaultsKey = "mm.demoMode"

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.defaultsKey) == nil,
           defaults.object(forKey: Self.legacyDefaultsKey) != nil {
            defaults.set(defaults.bool(forKey: Self.legacyDefaultsKey), forKey: Self.defaultsKey)
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        }
    }

    func startDemo() {
        // Sample data and real data are different stores: the assistant lets go of the one it
        // holds BEFORE this one is swapped under it (contract §4, law 42).
        MBAssistantSession.shared.detachNow()
        let schema = Schema(versionedSchema: GLCurrentSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        // Before anything is seeded: the taxpayer-ID store swaps to memory for the whole sample
        // session, so neither the seed nor the TIN forms inside sample mode can read or overwrite
        // the owner's real SSN/EIN in the device (and iCloud) Keychain.
        SecureTINStore.beginSampleSession()
        // The same for this iPhone's preferences (law 42, audit 2026-10-03 F149): the owner's
        // language, appearance, switches and lock come back on Exit, whatever the sample changed.
        // A relaunch re-seeding a running session keeps the values saved when it began.
        AppSettingsService.beginSampleSession(resuming: UserDefaults.standard.bool(forKey: Self.defaultsKey))
        do {
            let container = try ModelContainer(for: schema, configurations: config)
            // The SAME rich dataset the marketing screenshots use (Summit Tile &
            // Stone — real names, itemized invoices, payroll, receipts, a 1099),
            // not a thin placeholder seed. The sample-data door is the first
            // thing a new person sees; it has to look like a real business.
            DemoSeed.populate(container.mainContext)
            self.demoContainer = container
            self.isDemoActive = true
            UserDefaults.standard.set(true, forKey: Self.defaultsKey)
            GoldLifeID.shared.enterSampleMode()
        } catch {
            // In-memory container creation failing means the schema itself is
            // broken — DEBUG territory. Alert AND log all the same: a chip that
            // silently does nothing is the defect class, not the error.
            Self.log.fault("sample container failed to build: \(String(describing: error), privacy: .public)")
            seedError = String(describing: error)
            // Nothing was seeded, so hand the Keychain back rather than leaving the app in a
            // memory-backed TIN state it can never leave.
            SecureTINStore.endSampleSession()
            AppSettingsService.endSampleSession()
        }
    }

    func exitDemo() {
        // Sample data and real data are different stores: the assistant lets go of the one it
        // holds BEFORE this one is swapped under it (contract §4, law 42).
        MBAssistantSession.shared.detachNow()
        // Discards every taxpayer ID the sample session held and restores the real Keychain.
        SecureTINStore.endSampleSession()
        // Puts back every preference the sample changed (a no-op when no sample was running).
        AppSettingsService.endSampleSession()
        self.isDemoActive = false
        UserDefaults.standard.set(false, forKey: Self.defaultsKey)
        if GoldLifeID.shared.isSampleMode {
            GoldLifeID.shared.exitSampleMode()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDemoActive else { return }
            self.demoContainer = nil
        }
    }
}

// The sample-data card ("Exploring sample data … Exit") is GoldLifeUI's GLSampleDataBanner,
// shown only by the shared banner slot (MBSystemBanners.swift → GLSystemBannerStack; audit
// 2026-10-03 F158). Its Exit calls `exitDemo()` above.
