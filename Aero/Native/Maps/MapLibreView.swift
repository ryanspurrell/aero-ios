import SwiftUI
import UIKit
import MapLibre

/// The only file that draws with MapLibre Native (BSD-2-Clause, github.com/maplibre/maplibre-native, LICENSE.md; added through Swift Package
/// Manager from maplibre-gl-native-distribution 6.31.0). The map is a plug-in behind this one view: it is given a style document, the overlay data
/// and camera commands, and tells nothing back. Everything it asks for goes to the server address the style names, and `MapsNetwork` refuses the
/// rest.
struct MapLibreView: UIViewRepresentable {
    var style: Data
    var styleKey: String
    var overlay: MapsOverlay
    var look: MapsStore.Aim
    var bottomInset: CGFloat
    var accent: UIColor
    var night: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        MapsNetwork.installForMapLibre()
        let map = MLNMapView(frame: .zero)
        map.delegate = context.coordinator
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true        // the credit is drawn on the screen as plain words, always (MapsText.creditLine)
        map.compassView.isHidden = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsUserLocation = false
        map.accessibilityLabel = "Map"
        context.coordinator.map = map
        context.coordinator.load(style: style, key: styleKey)
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let c = context.coordinator
        c.accent = accent
        c.night = night
        c.overlay = overlay
        if map.contentInset.bottom != bottomInset { map.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0) }
        c.load(style: style, key: styleKey)
        c.draw()
        c.move(look)
    }

    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) { coordinator.cleanUp() }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        weak var map: MLNMapView?
        var overlay = MapsOverlay()
        var accent = UIColor.systemYellow
        var night = false
        private var loadedKey = ""
        private var styleLoaded = false
        private var lastSerial = 0
        private var pendingLook: MapsStore.Aim?
        private var styleFile: URL?
        private var drawnOverlay: MapsOverlay?
        private var drawnNight: Bool?

        /// The style document goes in a file in the app's own temporary folder (MapLibre reads a style from an address), and is removed with the
        /// screen. It holds the server's address, as the settings do.
        func load(style: Data, key: String) {
            guard key != loadedKey, let map else { return }
            loadedKey = key
            styleLoaded = false
            drawnOverlay = nil
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("fingus-map-style-\(UUID().uuidString).json")
            guard (try? style.write(to: file, options: [.atomic, .completeFileProtection])) != nil else { return }
            if let old = styleFile { try? FileManager.default.removeItem(at: old) }
            styleFile = file
            map.styleURL = file
        }

        func cleanUp() {
            if let file = styleFile { try? FileManager.default.removeItem(at: file) }
            styleFile = nil
        }

        deinit { if let file = styleFile { try? FileManager.default.removeItem(at: file) } }

        @objc(mapView:didFinishLoadingStyle:)
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            styleLoaded = true
            draw()
            if let look = pendingLook { pendingLook = nil; move(look) }
        }

        // MARK: overlays

        private static let ids = ["locareas", "locareas-edge", "locpath-case", "locpath", "locvisits", "locplaces", "locacc", "lochere"]

        func draw() {
            guard styleLoaded, let style = map?.style else { return }
            if drawnOverlay == overlay && drawnNight == night { return }
            drawnOverlay = overlay
            drawnNight = night
            for id in Coordinator.ids { if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) } }
            for id in Coordinator.ids { if let source = style.source(withIdentifier: id) { style.removeSource(source) } }

            let ground = night ? UIColor(red: 0.063, green: 0.067, blue: 0.031, alpha: 1) : UIColor.white
            let ink = night ? UIColor(red: 0.933, green: 0.941, blue: 0.831, alpha: 1) : UIColor(red: 0.129, green: 0.129, blue: 0.051, alpha: 1)

            func areaSource() -> MLNShapeSource {
                var shapes: [MLNShape & MLNFeature] = []
                for p in overlay.places {
                    var ring = MapsOverlay.area(of: p)
                    shapes.append(MLNPolygonFeature(coordinates: &ring, count: UInt(ring.count)))
                }
                return MLNShapeSource(identifier: "locareas", shape: MLNShapeCollectionFeature(shapes: shapes), options: nil)
            }
            let areas = areaSource()
            style.addSource(areas)
            let fill = MLNFillStyleLayer(identifier: "locareas", source: areas)
            fill.fillColor = NSExpression(forConstantValue: accent)
            fill.fillOpacity = NSExpression(forConstantValue: 0.16)
            style.addLayer(fill)
            let edge = MLNLineStyleLayer(identifier: "locareas-edge", source: areas)
            edge.lineColor = NSExpression(forConstantValue: accent)
            edge.lineWidth = NSExpression(forConstantValue: 1.5)
            edge.lineOpacity = NSExpression(forConstantValue: 0.7)
            style.addLayer(edge)

            if overlay.path.count > 1 {
                var line = overlay.path.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let pathSource = MLNShapeSource(identifier: "locpath", shape: MLNPolylineFeature(coordinates: &line, count: UInt(line.count)), options: nil)
                style.addSource(pathSource)
                let casing = MLNLineStyleLayer(identifier: "locpath-case", source: pathSource)
                casing.lineColor = NSExpression(forConstantValue: ground)
                casing.lineWidth = NSExpression(forConstantValue: 8)
                style.addLayer(casing)
                let stroke = MLNLineStyleLayer(identifier: "locpath", source: pathSource)
                stroke.lineColor = NSExpression(forConstantValue: night ? accent : ink)
                stroke.lineWidth = NSExpression(forConstantValue: 4.5)
                style.addLayer(stroke)
            }

            func points(_ id: String, _ coords: [CLLocationCoordinate2D]) -> MLNShapeSource {
                var shapes: [MLNShape & MLNFeature] = []
                for c in coords {
                    let f = MLNPointFeature()
                    f.coordinate = c
                    shapes.append(f)
                }
                let s = MLNShapeSource(identifier: id, shape: MLNShapeCollectionFeature(shapes: shapes), options: nil)
                style.addSource(s)
                return s
            }
            let visits = MLNCircleStyleLayer(identifier: "locvisits", source: points("locvisits", overlay.visits))
            visits.circleRadius = NSExpression(forConstantValue: 6)
            visits.circleColor = NSExpression(forConstantValue: ground)
            visits.circleStrokeWidth = NSExpression(forConstantValue: 3)
            visits.circleStrokeColor = NSExpression(forConstantValue: night ? accent : ink)
            style.addLayer(visits)

            let places = MLNCircleStyleLayer(identifier: "locplaces", source: points("locplaces", overlay.places.map(\.coordinate)))
            places.circleRadius = NSExpression(forConstantValue: 8)
            places.circleColor = NSExpression(forConstantValue: accent)
            places.circleStrokeWidth = NSExpression(forConstantValue: 2)
            places.circleStrokeColor = NSExpression(forConstantValue: ink)
            style.addLayer(places)

            if let here = overlay.here {
                if let acc = overlay.hereAccuracy {
                    var ring = MapsOverlay.circle(here, metres: acc)
                    let s = MLNShapeSource(identifier: "locacc", shape: MLNPolygonFeature(coordinates: &ring, count: UInt(ring.count)), options: nil)
                    style.addSource(s)
                    let halo = MLNFillStyleLayer(identifier: "locacc", source: s)
                    halo.fillColor = NSExpression(forConstantValue: accent)
                    halo.fillOpacity = NSExpression(forConstantValue: 0.22)
                    style.addLayer(halo)
                }
                let dot = MLNCircleStyleLayer(identifier: "lochere", source: points("lochere", [here]))
                dot.circleRadius = NSExpression(forConstantValue: 9)
                dot.circleColor = NSExpression(forConstantValue: overlay.hereOld ? UIColor.systemGray : accent)
                dot.circleStrokeWidth = NSExpression(forConstantValue: 3)
                dot.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                style.addLayer(dot)
            }
        }

        // MARK: camera

        func move(_ look: MapsStore.Aim) {
            guard look.serial != lastSerial, let map else { return }
            guard styleLoaded else { pendingLook = look; return }
            lastSerial = look.serial
            let pad = Look.Space.mapFit
            func fit(_ pts: [CLLocationCoordinate2D]) -> Bool {
                guard let first = pts.first else { return false }
                if pts.count == 1 { map.setCenter(first, zoomLevel: 15, animated: true); return true }
                var sw = first, ne = first
                for p in pts {
                    sw = CLLocationCoordinate2D(latitude: min(sw.latitude, p.latitude), longitude: min(sw.longitude, p.longitude))
                    ne = CLLocationCoordinate2D(latitude: max(ne.latitude, p.latitude), longitude: max(ne.longitude, p.longitude))
                }
                map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: sw, ne: ne), edgePadding: pad, animated: true, completionHandler: nil)
                return true
            }
            switch look.kind {
            case .here:
                if let here = overlay.here { map.setCenter(here, zoomLevel: max(map.zoomLevel, 14), animated: true) }
            case .point(let lat, let lon):
                map.setCenter(CLLocationCoordinate2D(latitude: lat, longitude: lon), zoomLevel: max(map.zoomLevel, 15), animated: true)
            case .trip(let from, let to):
                _ = fit(overlay.path.filter { $0.time >= from && $0.time <= to }.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
            case .day:
                if !fit(overlay.path.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }), let here = overlay.here {
                    map.setCenter(here, zoomLevel: 14, animated: false)
                }
            }
        }
    }
}
