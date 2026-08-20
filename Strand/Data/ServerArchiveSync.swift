import Foundation
import Security

/// Uploads NOOP's existing full-database `.noopbak` snapshot to a self-hosted NOOP server.
///
/// This deliberately reuses `DataBackup.writeBackup`: the server archive is the same verified,
/// compressed whole-DB backup used by Backup & Sync, so it captures raw HR samples, workouts,
/// sleeps, metrics, nutrition, settings manifest, and future tables without maintaining a fragile
/// table-by-table exporter. Uploads are authenticated with the sync password stored in Keychain.
enum ServerArchiveSync {
    static let baseURLKey = "serverArchive.baseURL"
    static let enabledKey = "serverArchive.enabled"
    static let lastSuccessDayKey = "serverArchive.lastSuccessDay"
    static let lastSuccessMsKey = "serverArchive.lastSuccessMs"
    static let lastStatusKey = "serverArchive.lastStatus"
    static let defaultBaseURL = "http://192.168.1.219"

    private static let dayMs = 24 * 60 * 60 * 1000

    static var baseURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
            return stored.isEmpty ? defaultBaseURL : stored
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLKey) }
    }

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var lastSuccessMs: Int { UserDefaults.standard.integer(forKey: lastSuccessMsKey) }
    static var lastStatus: String { UserDefaults.standard.string(forKey: lastStatusKey) ?? "Not uploaded yet." }
    static var hasPassword: Bool { password() != nil }

    static func savePassword(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }
        SecItemDelete(keychainQuery() as CFDictionary)
        var item = keychainQuery()
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func clearPassword() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }

    static func catchUpIfDue(checkpoint: @escaping () async -> Bool) async {
        guard enabled else { return }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000.0)
        let today = Repository.localDayKey(Date())
        let lastDay = UserDefaults.standard.string(forKey: lastSuccessDayKey) ?? ""
        guard lastDay != today || nowMs - lastSuccessMs >= dayMs else { return }
        _ = await uploadNow(checkpoint: checkpoint)
    }

    @discardableResult
    static func uploadNow(checkpoint: @escaping () async -> Bool) async -> Bool {
        guard enabled else { setStatus("Server archive is off."); return false }
        guard let password = password(), !password.isEmpty else { setStatus("Server archive password is missing."); return false }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000.0)
        let fileName = BackupSync.snapshotName(nowMs)
        guard let endpoint = archiveEndpointURL(baseURL: baseURL, day: Repository.localDayKey(Date()), filename: fileName) else {
            setStatus("Server archive URL is invalid or not allowed.")
            return false
        }

        let fm = FileManager.default
        let staged = fm.temporaryDirectory.appendingPathComponent(fileName)
        try? fm.removeItem(at: staged)
        defer { try? fm.removeItem(at: staged) }

        guard case .exported = await DataBackup.writeBackup(checkpoint: checkpoint, to: staged) else {
            setStatus("Could not create verified local backup for server upload.")
            return false
        }

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(fileName, forHTTPHeaderField: "X-NOOP-Filename")
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: staged)
            guard let http = response as? HTTPURLResponse else {
                setStatus("Server archive upload failed: no HTTP response.")
                return false
            }
            guard (200..<300).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                setStatus("Server archive upload failed: \(detail.prefix(180))")
                return false
            }
            let today = Repository.localDayKey(Date())
            UserDefaults.standard.set(today, forKey: lastSuccessDayKey)
            UserDefaults.standard.set(nowMs, forKey: lastSuccessMsKey)
            setStatus("Uploaded raw NOOP backup for \(today).")
            return true
        } catch {
            setStatus("Server archive upload failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func archiveEndpointURL(baseURL raw: String, day: String, filename: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, let base = URL(string: trimmed), isAllowedBaseURL(base) else { return nil }
        guard var components = URLComponents(url: base.appendingPathComponent("v1/archive/raw-snapshots"), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "day", value: day),
            URLQueryItem(name: "source", value: "ios"),
            URLQueryItem(name: "filename", value: filename)
        ]
        return components.url
    }

    private static func isAllowedBaseURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") { return true }
        if host == "127.0.0.1" || host.hasPrefix("192.168.") || host.hasPrefix("10.") { return true }
        if host.hasPrefix("172."),
           let second = host.split(separator: ".").dropFirst().first,
           let octet = Int(second), (16...31).contains(octet) { return true }
        return false
    }

    private static func password() -> String? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "NOOPServerArchive",
            kSecAttrAccount as String: "sync-password"
        ]
    }

    private static func setStatus(_ status: String) {
        UserDefaults.standard.set(status, forKey: lastStatusKey)
    }
}
