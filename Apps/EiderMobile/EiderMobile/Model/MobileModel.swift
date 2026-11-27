import EiderCore
import Foundation
import Observation

enum AppTab: Hashable {
    case browse, library, updates, sources, certificates
}

/// A download in flight, shown on the row or button that started it.
struct Transfer: Equatable {
    var received: Int64 = 0
    var expected: Int64?

    var fraction: Double? {
        guard let expected, expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }
}

/// What the Install sheet is open for.
struct InstallRequest: Identifiable {
    let id = UUID()
    let ipa: LibraryIPA
    /// The installed app this replaces (Updates), whose signing id it keeps.
    var replacing: InstalledApp?
}

/// The app's state, driven the way the Mac app's AppModel drives EiderCore:
/// stores are actors, the catalog index and filtering run detached, and only
/// the published results land on the main actor.
@MainActor @Observable
final class MobileModel {
    @ObservationIgnored let paths: EiderPaths
    @ObservationIgnored let sourceStore: SourceStore
    @ObservationIgnored let downloads: DownloadManager
    @ObservationIgnored let library: LibraryStore
    @ObservationIgnored let certificateStore: CertificateStore
    @ObservationIgnored let signer: any SigningService
    @ObservationIgnored let installer: any DeviceInstaller

    var tab: AppTab = .browse
    var showingSettings = false
    var errorMessage: String?
    var pendingLink: DeepLink?
    var installRequest: InstallRequest?

    // Sources
    var sources: [CatalogSource] = []
    var refreshFailures: [URL: String] = [:]
    var isRefreshing = false
    var isAddingSource = false
    var newSourceText = ""
    var importProgress: (done: Int, total: Int)?
    var importResult: SourceImportResult?

    // Browse
    var catalog: [SourcedApp] = []
    var browseIndex = BrowseIndex.empty
    var browseResults: [SourcedApp] = []
    var filter = BrowseFilter() {
        didSet { if filter != oldValue { publishBrowseResults(debounced: true) } }
    }
    @ObservationIgnored var indexTask: Task<Void, Never>?
    @ObservationIgnored var filterTask: Task<Void, Never>?
    @ObservationIgnored var indexGeneration = 0
    @ObservationIgnored var filterGeneration = 0

    // Library and updates
    var ipas: [LibraryIPA] = []
    var installed: [InstalledApp] = []
    var updates: [UpdateOffer<InstalledApp>] = []
    var transfers: [String: Transfer] = [:]
    /// Update All runs one job at a time; the Updates row shows its steps.
    var updateJobs: [String: InstallJob] = [:]
    var isUpdatingAll = false

    // Certificates
    var certificates: [CertificateRecord] = []
    var defaultCertificateID: UUID?
    /// Asked once per certificate per session: OCSP is a network round trip.
    var revocation: [UUID: RevocationState] = [:]

    // Installing on this device
    var installReadiness: InstallReadiness?
    var isCheckingReadiness = false

    init(
        paths: EiderPaths = EiderPaths(),
        signer: any SigningService = AppSigner(),
        installer: any DeviceInstaller = AppInstaller()
    ) {
        self.paths = paths
        self.sourceStore = SourceStore(paths: paths)
        self.downloads = DownloadManager(paths: paths)
        self.library = LibraryStore(paths: paths)
        self.certificateStore = CertificateStore(paths: paths, signer: signer)
        self.signer = signer
        self.installer = installer
    }

    /// Everything from disk, once at launch; then stale sources in the background.
    func start() async {
        do {
            try paths.ensureMobile()
        } catch {
            report(error)
        }
        await reloadCatalog()
        await reloadLibrary()
        await reloadCertificates()
        await checkInstallReadiness()
        await refreshStaleSources()
    }

    var defaultCertificate: CertificateRecord? {
        certificates.first { $0.id == defaultCertificateID } ?? certificates.first
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    // MARK: Links and shared files

    /// `eider://` links ask first, as on the Mac: a web page must not add a
    /// source or start a download by itself. An IPA opened from Files or the
    /// share sheet arrives as a file URL and goes straight into the library,
    /// since the person chose it.
    func handle(_ url: URL) async {
        if url.isFileURL {
            await importIPA(from: url)
            return
        }
        guard let link = DeepLink.parse(url) else {
            errorMessage = "Eider cannot open that link."
            return
        }
        pendingLink = link
    }

    func confirmPendingLink() async {
        guard let link = pendingLink else { return }
        pendingLink = nil
        switch link {
        case .addSource(let url):
            tab = .sources
            await addSource(url)
        case .install(let url):
            tab = .library
            await getLinkedIPA(url)
        }
    }
}
