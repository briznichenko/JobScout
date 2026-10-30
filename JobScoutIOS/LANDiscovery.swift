//
//  LANDiscovery.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import Foundation
import Observation

struct DiscoveredServer: Identifiable {
    let id: String
    let name: String
    let url: URL
}

@MainActor @Observable
final class LANDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private(set) var servers: [DiscoveredServer] = []
    private(set) var message: String?
    @ObservationIgnored private var browser: NetServiceBrowser?
    @ObservationIgnored private var resolving: [NetService] = []

    func start() {
        stop()
        message = "Looking for JobScout servers…"
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_jobscout._tcp.", inDomain: "local.")
    }

    func stop() {
        browser?.stop()
        browser = nil
        resolving.forEach { $0.stop() }
        resolving.removeAll()
        servers.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let identity = service.domain + service.type + service.name
        servers.removeAll { $0.id == identity }
        resolving.removeAll { candidate in
            let matches = candidate.domain == service.domain && candidate.type == service.type && candidate.name == service.name
            if matches { candidate.stop() }
            return matches
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let records = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        guard records["api"].flatMap({ String(data: $0, encoding: .utf8) }) == "1" else { return }
        let tls = records["tls"].flatMap { String(data: $0, encoding: .utf8) } == "1"
        var address = URLComponents()
        address.scheme = tls ? "https" : "http"
        address.host = host.hasSuffix(".") ? String(host.dropLast()) : host
        address.port = sender.port
        guard let url = address.url else { return }
        let identity = sender.domain + sender.type + sender.name
        servers.removeAll { $0.id == identity }
        servers.append(DiscoveredServer(id: identity, name: sender.name, url: url))
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        message = nil
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        message = "Discovery is unavailable. Check local-network permission or enter the server address manually."
    }
}
