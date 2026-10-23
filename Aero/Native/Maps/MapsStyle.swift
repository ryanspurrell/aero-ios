import Foundation

// The map's look: the web app's Location map (Protomaps' layers, taken toward the app's own palette: tools/make_map_style.js writes
// Resources/Map/layers_light.json and layers_dark.json from the web app's vendored @protomaps/basemaps 5.7.2, BSD-3-Clause), with the one
// vector source, the letters and the symbols all on the person's own server (aero_web.py `private_location_tile`, `private_location_map`).
// Protomaps' map design is CC0; its code BSD-3-Clause; the map data is OpenStreetMap's, ODbL: "© OpenStreetMap contributors" and "Protomaps" are
// drawn on the screen at all times (MapsText.creditLine).

enum MapsStyle {
    /// The routes, under the address the app was given (the page's `%(path)s`).
    static let mapPath = "private/location/map/"

    /// The base of the map routes, with a trailing slash.
    static func mapBase(_ server: URL) -> String {
        var text = server.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return text + "/" + mapPath
    }

    /// The style document (version 8) for one look, or nil when the bundled layers are unreadable.
    static func json(server: URL, night: Bool, layers: Data) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: layers), let layerList = parsed as? [Any] else { return nil }
        let base = mapBase(server)
        let style: [String: Any] = [
            "version": 8,
            "glyphs": base + "fonts/{fontstack}/{range}.pbf",
            "sprite": base + "sprites/" + (night ? "dark" : "light"),
            // 15 is the PC's own limit for squares; MapLibre draws past it from the last one
            "sources": ["tiles": ["type": "vector", "tiles": [base + "tiles/{z}/{x}/{y}.mvt"], "minzoom": 0, "maxzoom": 15]],
            "layers": layerList,
        ]
        return try? JSONSerialization.data(withJSONObject: style)
    }

    /// The bundled layers for a look.
    static func bundledLayers(night: Bool, bundle: Bundle = Bundle(for: MapsBundleToken.self)) -> Data? {
        guard let url = bundle.url(forResource: night ? "layers_dark" : "layers_light", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Every http(s) address that appears anywhere in a JSON document (what the map would ask for), for the test that none is off the server.
    static func addresses(in json: Data) -> [URL] {
        guard let parsed = try? JSONSerialization.jsonObject(with: json) else { return [] }
        var found: [URL] = []
        func walk(_ value: Any) {
            if let text = value as? String {
                let lower = text.lowercased()
                if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                    // the {z}/{x}/{y} and {fontstack} placeholders are not valid in a URL: fill them before reading the host
                    let filled = text.replacingOccurrences(of: "{z}", with: "1").replacingOccurrences(of: "{x}", with: "1")
                        .replacingOccurrences(of: "{y}", with: "1").replacingOccurrences(of: "{fontstack}", with: "Noto%20Sans%20Regular")
                        .replacingOccurrences(of: "{range}", with: "0-255")
                    if let url = URL(string: filled) { found.append(url) }
                }
            } else if let list = value as? [Any] {
                list.forEach(walk)
            } else if let object = value as? [String: Any] {
                object.values.forEach(walk)
            }
        }
        walk(parsed)
        return found
    }
}

/// Only here so the bundled files are found in the app's bundle, also when the tests run inside it.
final class MapsBundleToken {}
