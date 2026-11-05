import SwiftUI
import MapKit

@MainActor final class AddressSuggestions: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    @Published var message = ""
    private let completer = MKLocalSearchCompleter()
    override init() { super.init(); completer.delegate = self; completer.resultTypes = [.address, .pointOfInterest] }
    func search(_ text: String) {
        message = ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { completer.queryFragment = ""; suggestions = []; return }
        completer.queryFragment = text
    }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { suggestions = Array(completer.results.prefix(5)) }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { suggestions = []; message = "Address suggestions are unavailable. You can still enter a location." }
}
struct EventLocationSection: View {
    @Binding var item: Item
    @StateObject private var addresses = AddressSuggestions()
    @State private var searching = false
    @State private var resolving = false
    var body: some View {
        Section("Location") {
            TextField("Search address or place", text: Binding(get: { item.location ?? "" }, set: {
                item.location = $0; item.latitude = nil; item.longitude = nil; searching = true; addresses.search($0)
            }))
            if resolving { ProgressView("Finding location…") }
            if searching {
                ForEach(Array(addresses.suggestions.enumerated()), id: \.offset) { _, suggestion in
                    Button {
                        let query = item.location ?? ""
                        resolving = true
                        Task {
                            defer { resolving = false }
                            do {
                                let result = try await MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion)).start()
                                guard item.location == query, let place = result.mapItems.first else { return }
                                item.location = [suggestion.title, suggestion.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
                                item.latitude = place.placemark.coordinate.latitude; item.longitude = place.placemark.coordinate.longitude
                                searching = false
                            } catch { addresses.message = "Could not look up that place. Try again or keep the typed address." }
                        }
                    } label: {
                        VStack(alignment: .leading) { Text(suggestion.title); Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }.disabled(resolving)
                }
            }
            if !(item.location ?? "").isEmpty { Button("Open in Maps", systemImage: "map") { Self.open(item) } }
            if !addresses.message.isEmpty { Text(addresses.message).font(.caption).foregroundStyle(.secondary) }
        }
    }
    static func open(_ item: Item) {
        if let lat = item.latitude, let lon = item.longitude {
            let place = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
            place.name = item.location; place.openInMaps()
        } else if let address = item.location {
            var url = URLComponents(string: "https://maps.apple.com/")!
            url.queryItems = [URLQueryItem(name: "q", value: address)]
            if let url = url.url { UIApplication.shared.open(url) }
        }
    }
}
