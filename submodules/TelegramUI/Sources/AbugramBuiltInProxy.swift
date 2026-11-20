import Foundation
import Network
import TelegramCore
import MtProtoKit

// MARK: Abugram
// Built-in MTProxy support so the app connects where Telegram is blocked, without a VPN.
//
// On every launch the proxy list is downloaded from the Abugram repository (falling back to the
// list compiled into the app), every candidate is probed with a plain TCP connect from the device
// itself, and the first one that answers becomes the active proxy. Servers added by the user are
// never touched, and once the user switches proxies off, Abugram does not switch them back on.

private let abugramProxyListUrls: [URL] = [
    URL(string: "https://raw.githubusercontent.com/Abdulaziz0196/Telegram-iOS/master/abugram/proxies.txt")!,
    URL(string: "https://cdn.jsdelivr.net/gh/Abdulaziz0196/Telegram-iOS@master/abugram/proxies.txt")!
]

private let abugramManagedServersKey = "abugram.managedProxyServers"
private let abugramInitializedKey = "abugram.builtInProxyInitialized"
private let abugramMaxProbedServers = 40
private let abugramProbeTimeout: Double = 6.0

private let abugramFallbackProxyList = """
https://t.me/proxy?server=edgespindle.org&port=443&secret=eebec6acb2a5464709485d7cbeedd8612b686f66662e7275
https://t.me/proxy?server=Speed-speed.co.uk&port=443&secret=eef0eeb0bd9adc4fd4a93994ee3b2a216b63646e2e79656b74616e65742e636f6d
https://t.me/proxy?server=torobchesho.co.uk&port=443&secret=ee5f7ce28a2c4816c6c923dfd4d5630e01746f726f6263686573686f2e636f2e756b
https://t.me/proxy?server=proxy.nizya.club&port=443&secret=ee05cf8e164f926f4a664b2404d276a1d670726f78792e6e697a79612e636c7562
https://t.me/proxy?server=mobile.prxtg.top&port=443&secret=ee8ae40a2aa7554a058f3340b6449e4e666d6f62696c652e70727874672e746f70
https://t.me/proxy?server=Hel-hi.co.uk&port=443&secret=eef0eeb0bd9adc4fd4a93994ee3b2a216b63646e2e79656b74616e65742e636f6d
https://t.me/proxy?server=petros-es.co.uk&port=443&secret=ee79e344818749bd7ac519130220c25d09706574726f732d65732e636f2e756b
https://t.me/proxy?server=freeconnect.lol&port=443&secret=eeec15a78c3842e866c302c8526175a68c7975672d6c696e6b2e7275
https://t.me/proxy?server=tg.prxtg.top&port=443&secret=ee2d1bb45f31056d1063563fc6e38e5a1064726976652e676f6f676c652e636f6d
https://t.me/proxy?server=objectpeak.org&port=443&secret=ee15d9244d7aa802e81b1736133fe059c5686f66662e7275
"""

private func abugramDecodeProxySecret(_ string: String) -> Data? {
    let hexCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    var decoded: Data?
    if !string.isEmpty && string.count % 2 == 0 && string.unicodeScalars.allSatisfy({ hexCharacters.contains($0) }) {
        var bytes = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index ..< next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        decoded = bytes
    } else {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        decoded = Data(base64Encoded: base64)
    }
    guard let data = decoded, MTProxySecret.parseData(data) != nil else {
        return nil
    }
    return data
}

func abugramParseProxyLine(_ line: String) -> ProxyServerSettings? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.hasPrefix("#") {
        return nil
    }
    guard let components = URLComponents(string: trimmed), let queryItems = components.queryItems else {
        return nil
    }
    var server: String?
    var port: Int32?
    var secretString: String?
    for item in queryItems {
        switch item.name.lowercased() {
        case "server":
            server = item.value
        case "port":
            port = item.value.flatMap { Int32($0) }
        case "secret":
            secretString = item.value
        default:
            break
        }
    }
    guard var host = server, let portValue = port, let secretValue = secretString, let secret = abugramDecodeProxySecret(secretValue) else {
        return nil
    }
    while host.hasSuffix(".") {
        host.removeLast()
    }
    if host.isEmpty || portValue <= 0 || portValue > 65535 {
        return nil
    }
    return ProxyServerSettings(host: host, port: portValue, connection: .mtp(secret: secret))
}

private func abugramParseProxyList(_ text: String) -> [ProxyServerSettings] {
    var result: [ProxyServerSettings] = []
    var seen = Set<String>()
    for line in text.components(separatedBy: .newlines) {
        if let server = abugramParseProxyLine(line) {
            let key = abugramServerKey(server)
            if !seen.contains(key) {
                seen.insert(key)
                result.append(server)
            }
        }
    }
    return result
}

private func abugramServerKey(_ server: ProxyServerSettings) -> String {
    return "\(server.host):\(server.port)"
}

private func abugramDownloadProxyList(urls: [URL], completion: @escaping (String?) -> Void) {
    guard let url = urls.first else {
        completion(nil)
        return
    }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10.0)
    request.httpMethod = "GET"
    URLSession.shared.dataTask(with: request, completionHandler: { data, response, _ in
        if let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, let text = String(data: data, encoding: .utf8), !abugramParseProxyList(text).isEmpty {
            completion(text)
        } else {
            abugramDownloadProxyList(urls: Array(urls.dropFirst()), completion: completion)
        }
    }).resume()
}

private final class AbugramProxyProbe {
    private let queue = DispatchQueue(label: "abugram.proxy-probe")
    private var connections: [NWConnection] = []
    private var finished = false
    private var completion: ((ProxyServerSettings?) -> Void)?

    // Connects to every server at once and reports the first one that accepts a TCP connection.
    func start(servers: [ProxyServerSettings], timeout: Double, completion: @escaping (ProxyServerSettings?) -> Void) {
        self.queue.async { [self] in
            self.completion = completion
            for server in servers {
                guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: server.port)) else {
                    continue
                }
                let connection = NWConnection(host: NWEndpoint.Host(server.host), port: port, using: .tcp)
                // Strong capture: finish() clears every handler, and the timeout always calls it.
                connection.stateUpdateHandler = { state in
                    if case .ready = state {
                        self.finish(server)
                    }
                }
                self.connections.append(connection)
                connection.start(queue: self.queue)
            }
            if self.connections.isEmpty {
                self.finish(nil)
                return
            }
            self.queue.asyncAfter(deadline: .now() + timeout, execute: {
                self.finish(nil)
            })
        }
    }

    private func finish(_ server: ProxyServerSettings?) {
        if self.finished {
            return
        }
        self.finished = true
        for connection in self.connections {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        self.connections.removeAll()
        let completion = self.completion
        self.completion = nil
        completion?(server)
    }
}

private var abugramCurrentProbe: AbugramProxyProbe?

func abugramStartBuiltInProxy(updateSettings: @escaping (@escaping (ProxySettings) -> ProxySettings) -> Void) {
    abugramDownloadProxyList(urls: abugramProxyListUrls, completion: { text in
        var servers = abugramParseProxyList(text ?? "")
        if servers.isEmpty {
            servers = abugramParseProxyList(abugramFallbackProxyList)
        }
        if servers.isEmpty {
            return
        }
        let probed = Array(servers.prefix(abugramMaxProbedServers))
        let probe = AbugramProxyProbe()
        DispatchQueue.main.async {
            abugramCurrentProbe = probe
        }
        probe.start(servers: probed, timeout: abugramProbeTimeout, completion: { fastest in
            DispatchQueue.main.async {
                abugramCurrentProbe = nil
                abugramApplyProxies(servers: servers, fastest: fastest, updateSettings: updateSettings)
            }
        })
    })
}

private func abugramApplyProxies(servers: [ProxyServerSettings], fastest: ProxyServerSettings?, updateSettings: @escaping (@escaping (ProxySettings) -> ProxySettings) -> Void) {
    let defaults = UserDefaults.standard
    let previouslyManaged = Set(defaults.stringArray(forKey: abugramManagedServersKey) ?? [])
    let wasInitialized = defaults.bool(forKey: abugramInitializedKey)
    let newManagedKeys = servers.map(abugramServerKey)

    defaults.set(newManagedKeys, forKey: abugramManagedServersKey)

    updateSettings({ settings in
        var settings = settings

        // Drop proxies that Abugram added earlier and that are no longer in the list; keep the user's own.
        settings.servers = settings.servers.filter { !previouslyManaged.contains(abugramServerKey($0)) || newManagedKeys.contains(abugramServerKey($0)) }
        let existingKeys = Set(settings.servers.map(abugramServerKey))
        for server in servers where !existingKeys.contains(abugramServerKey(server)) {
            settings.servers.append(server)
        }

        let activeIsManaged: Bool
        if let activeServer = settings.activeServer {
            let key = abugramServerKey(activeServer)
            activeIsManaged = previouslyManaged.contains(key) || newManagedKeys.contains(key)
        } else {
            activeIsManaged = true
        }
        // The user turned the built-in proxy off: respect that.
        let userDisabled = wasInitialized && !settings.enabled
        if activeIsManaged && !userDisabled, let fastest = fastest {
            settings.activeServer = fastest
            settings.enabled = true
            // Only now has Abugram switched the proxy on; from here a disabled proxy means the user chose it.
            UserDefaults.standard.set(true, forKey: abugramInitializedKey)
        } else if let activeServer = settings.activeServer, !settings.servers.contains(activeServer) {
            settings.activeServer = nil
            settings.enabled = false
        }
        return settings
    })
}
