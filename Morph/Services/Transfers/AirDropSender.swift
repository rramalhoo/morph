import AppKit

/// Sends files with macOS's own AirDrop service. macOS picks the recipient and shows its own
/// confirmation; Morph learns only that the share finished or failed, never bytes or receipt.
@MainActor
final class AirDropSender: NSObject, NSSharingServiceDelegate {
    private let transfers: TransferManager
    private var pending: [ObjectIdentifier: String] = [:]
    private var counter = 0

    init(transfers: TransferManager) {
        self.transfers = transfers
    }

    var isAvailable: Bool { NSSharingService(named: .sendViaAirDrop) != nil }

    /// Returns false if AirDrop isn't available here, or can't take these files.
    @discardableResult
    func send(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            return false
        }
        counter += 1
        let id = "airdrop-send-\(counter)"
        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        guard (try? transfers.begin(Transfer(id: id, kind: .airDropSend, name: name, source: .morph,
                                             state: .transferring))) != nil else { return false }
        service.delegate = self
        pending[ObjectIdentifier(service)] = id
        service.perform(withItems: urls)
        return true
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let key = ObjectIdentifier(sharingService)
        MainActor.assumeIsolated { complete(key, state: .completed, error: nil) }
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        let key = ObjectIdentifier(sharingService)
        // Closing the picker reports a user-cancelled error. That's a choice, not a failure.
        let cancelled = (error as NSError).code == NSUserCancelledError
        let message = error.localizedDescription
        MainActor.assumeIsolated { complete(key, state: cancelled ? .cancelled : .failed, error: message) }
    }

    private func complete(_ key: ObjectIdentifier, state: TransferState, error: String?) {
        guard let id = pending.removeValue(forKey: key) else { return }
        _ = try? transfers.finish(id: id, state: state, error: error)
    }
}
