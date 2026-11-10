import Foundation

extension DeepLink {
    /// The full address the link carries, shown whole before anything happens.
    public var url: URL {
        switch self {
        case .addSource(let url), .install(let url): return url
        }
    }

    public var verb: String {
        switch self {
        case .addSource: return "add this source"
        case .install: return "download and install this app"
        }
    }
}

extension AppModel {
    // MARK: Install options

    /// Every install, from any entry point, goes through the options sheet first.
    public func requestInstall(_ request: InstallRequest) {
        pendingInstall = PendingInstall(
            request: request, draft: InstallOptionsDraft(destination: settings.defaultInstallLocation))
    }

    public func confirmPendingInstall() {
        guard let pending = pendingInstall else { return }
        pendingInstall = nil
        activity.start(pending.request, options: pending.draft.options())
        selection = .activity
    }

    public func cancelPendingInstall() {
        pendingInstall = nil
    }

    // MARK: Files and links from outside

    /// Local `.ipa` files from a drop, File > Install IPA or opening a document.
    /// Returns whether anything was taken.
    @discardableResult
    public func handleFiles(_ urls: [URL]) -> Bool {
        guard let ipa = urls.first(where: { $0.isFileURL && $0.pathExtension.lowercased() == "ipa" }) else { return false }
        requestInstall(.localIPA(ipa))
        return true
    }

    /// Opened URLs: `eider://` links wait for confirmation, `.ipa` files go to
    /// the options sheet. Links are untrusted input (any web page can send one).
    public func handleOpened(_ urls: [URL]) {
        for url in urls {
            if url.isFileURL { handleFiles([url]) } else { handleDeepLink(url) }
        }
    }

    public func handleDeepLink(_ url: URL) {
        guard let link = DeepLink.parse(url) else {
            errorMessage = "Eider could not use that link: \(url.absoluteString)"
            return
        }
        pendingLink = link
    }

    /// The person saw the full address and agreed. An install link still goes
    /// through the options sheet, so nothing installs from one click.
    public func confirmPendingLink() async {
        guard let link = pendingLink else { return }
        pendingLink = nil
        switch link {
        case .addSource(let url):
            selection = .sources
            await addSource(url)
        case .install(let url):
            requestInstall(.url(url))
        }
    }

    public func dismissPendingLink() {
        pendingLink = nil
    }

    // MARK: Settings

    public func setDefaultInstallLocation(_ url: URL) {
        var updated = settings
        updated.defaultInstallLocation = url
        do {
            try updated.save(to: paths)
            settings = updated
        } catch {
            errorMessage = "Could not save the setting: \(error.localizedDescription)"
        }
    }

    // MARK: Help

    public func checkForUpdates() async {
        releaseCheck = .checking
        releaseCheck = await releaseChecker.run()
    }

    public func dismissReleaseCheck() {
        releaseCheck = .idle
    }
}
