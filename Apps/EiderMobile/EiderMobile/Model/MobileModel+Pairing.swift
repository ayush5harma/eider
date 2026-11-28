import Foundation
import UIKit

extension MobileModel {
    /// Where a pairing file can be copied in from a Mac, since Documents is visible to Files and to
    /// `devicectl device copy to --domain-type appDataContainer`. Read once, then deleted: the
    /// file must not stay where a backup or a file share can reach it.
    static var pairingInbox: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pairing", isDirectory: true)
    }

    static let localDevVPNStore = URL(string: "https://apps.apple.com/app/id6755608044")!
    /// `scheme=eider` asks the VPN app to come back to Eider once it is on.
    static let localDevVPNEnable = URL(string: "localdevvpn://enable?scheme=eider")!

    /// Whether the chosen method has what an install needs, as of the last check.
    var isInstallSetupReady: Bool {
        switch installMethod {
        case .manifestServer: installReadiness == .ready
        case .pairing: pairingReadiness == .ready
        }
    }

    /// The check for whichever method is chosen; every caller that gates an install goes through it.
    func checkInstallSetup() async {
        switch installMethod {
        case .manifestServer: await checkInstallReadiness()
        case .pairing: await checkPairing()
        }
    }

    /// Picks up a file left in the inbox, then asks the service whether the pairing file is
    /// accepted. Without a file there is nothing to ask.
    func checkPairing() async {
        isCheckingPairing = true
        defer { isCheckingPairing = false }
        importPairingInbox()
        guard let file = PairingKeychain.load() else {
            hasPairingFile = false
            pairingHost = nil
            pairingReadiness = nil
            return
        }
        hasPairingFile = true
        if pairingHost == nil { pairingHost = try? pairing.validate(pairingFile: file) }
        pairingReadiness = await pairing.check(pairingFile: file)
    }

    /// Validates and stores a chosen file; returns the message to show when it is refused.
    func importPairingFile(_ data: Data) async -> String? {
        if let refusal = storePairingFile(data) { return refusal }
        await checkPairing()
        return nil
    }

    func removePairingFile() {
        PairingKeychain.delete()
        hasPairingFile = false
        pairingHost = nil
        pairingReadiness = nil
        pairingMessage = nil
    }

    /// Opens LocalDevVPN's enable link, or its App Store page when the app is not installed.
    func openLocalDevVPN() async {
        if await UIApplication.shared.open(Self.localDevVPNEnable) { return }
        await UIApplication.shared.open(Self.localDevVPNStore)
    }

    func openLocalDevVPNStore() async {
        await UIApplication.shared.open(Self.localDevVPNStore)
    }

    private func storePairingFile(_ data: Data) -> String? {
        do {
            let host = try pairing.validate(pairingFile: data)
            try PairingKeychain.set(data)
            hasPairingFile = true
            pairingHost = host
            pairingReadiness = nil
            pairingMessage = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Every file in Documents/Pairing that validates goes into the Keychain and is deleted; one
    /// that does not is left for the person to see, with the reason in `pairingMessage`.
    private func importPairingInbox() {
        let directory = Self.pairingInbox
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !file.hasDirectoryPath {
            guard let data = try? Data(contentsOf: file) else { continue }
            if let refusal = storePairingFile(data) {
                pairingMessage = "\(file.lastPathComponent): \(refusal)"
            } else {
                try? manager.removeItem(at: file)
            }
        }
    }
}
