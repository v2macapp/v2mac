import MapKit
import SwiftUI
import V2MacCore

/// What the core's rule files offer, read from the asset folder the core uses.
struct GeoCatalog: Sendable {
    struct Country: Identifiable, Hashable, Sendable {
        let code: String
        let name: String
        let englishName: String
        /// `countriesFile` when only the downloaded file has the country's ranges.
        var ipFile: String?
        /// In neither file: shown with a download button.
        var missing = false
        var id: String { code }
        /// Regional indicator letters, which every system font draws as the flag.
        var flag: String {
            String(code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }.map(Character.init))
        }
    }

    var countries: [Country] = []
    var siteTags: Set<String> = []
    /// Every list as a rule: `geosite:<tag>`, and `geoip:<tag>` for the ones that are not countries.
    var lists: [String] = []
    var isLoaded = false

    func country(_ code: String) -> Country? { countries.first { $0.code == code } }

    /// The rules of `rules` that the files can satisfy, so a rule never names a missing list.
    func available(_ rules: [String]) -> Set<String> { Set(rules.filter(lists.contains)) }

    /// Every country's address ranges, downloaded on request; the bundled `geoip.dat` has only a few.
    static let countriesFile = "countries-geoip.dat"
    static let countriesURL = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat")!

    static func load() async -> GeoCatalog {
        let assets = AppPaths.assetsDirectory
        return await Task.detached {
            let ipTags = GeoTags.read(contentsOf: assets.appendingPathComponent("geoip.dat"))
            let siteTags = GeoTags.read(contentsOf: assets.appendingPathComponent("geosite.dat"))
            let builtIn = Set(ipTags.filter(GeoTags.isCountry))
            let downloaded = Set(GeoTags.read(contentsOf: assets.appendingPathComponent(countriesFile)).filter(GeoTags.isCountry))
            let iso = Locale.Region.isoRegions.map { $0.identifier.lowercased() }.filter(GeoTags.isCountry)
            let english = Locale(identifier: "en")
            let countries = builtIn.union(downloaded).union(iso).compactMap { code -> Country? in
                guard let englishName = english.localizedString(forRegionCode: code.uppercased()) else { return nil }
                let name = Locale.current.localizedString(forRegionCode: code.uppercased()) ?? englishName
                return Country(code: code, name: name, englishName: englishName,
                               ipFile: builtIn.contains(code) ? nil : countriesFile,
                               missing: !builtIn.contains(code) && !downloaded.contains(code))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let lists = siteTags.map { "geosite:\($0)" } + ipTags.filter { !GeoTags.isCountry($0) }.map { "geoip:\($0)" }
            return GeoCatalog(countries: countries, siteTags: Set(siteTags), lists: lists.sorted(), isLoaded: true)
        }.value
    }
}

// MARK: - Countries

struct CountryPicker: View {
    @Environment(AppModel.self) private var model
    let catalog: GeoCatalog
    @Binding var selected: Set<String>
    @Binding var options: CountryRuleOptions
    @State private var search = ""
    @State private var onlySelected = false

    private var shown: [GeoCatalog.Country] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return catalog.countries.filter { country in
            (!onlySelected || selected.contains(country.code)) && (query.isEmpty
                || country.name.localizedStandardContains(query)
                || country.englishName.localizedStandardContains(query)
                || country.code.caseInsensitiveCompare(query) == .orderedSame)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SearchField(prompt: "Search \(catalog.countries.count) countries", text: $search)
                    .padding(10)
                List(shown) { country in
                    if country.missing {
                        // No ranges for it yet: one download brings every country's.
                        HStack {
                            Button {
                                Task { await model.ruleCatalog.downloadCountries(routes: model.regionPacks.downloadRoutes()) }
                            } label: {
                                if model.ruleCatalog.downloadingCountries { ProgressView().controlSize(.mini) }
                                else { Image(systemName: "arrow.down.circle").foregroundStyle(.tint) }
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.ruleCatalog.downloadingCountries)
                            .help("Download the IP ranges of every country (about 16 MB)")
                            row(country).foregroundStyle(.secondary)
                        }
                    } else {
                        Toggle(isOn: Binding(
                            get: { selected.contains(country.code) },
                            set: { on in if on { selected.insert(country.code) } else { selected.remove(country.code) } }
                        )) { row(country) }
                        .toggleStyle(.checkbox)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if shown.isEmpty { ContentUnavailableView.search(text: search) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let error = model.ruleCatalog.countriesError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        Toggle("Selected only", isOn: $onlySelected)
                        Spacer()
                        Button("Clear") { selected = [] }.disabled(selected.isEmpty)
                    }
                    Text("For each country, add:").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    Toggle("IP ranges (geoip)", isOn: $options.ipRanges)
                        .help("Every address registered in the country.")
                    Toggle("Country domain (.ir, .de, …)", isOn: $options.topLevelDomain)
                        .help("Every name under the country's top-level domain.")
                    Toggle("Known sites (geosite)", isOn: $options.knownSites)
                        .help("Lists of the country's sites on other domains, such as .com, where the rule file has one.")
                }
                .toggleStyle(.checkbox)
                .padding(12)
            }
            .frame(width: 320)
            Divider()
            CountryMap(catalog: catalog, selected: $selected)
        }
    }

    private func row(_ country: GeoCatalog.Country) -> some View {
        HStack {
            Text(country.flag)
            Text(country.name).lineLimit(1)
            Spacer()
            Text(country.code.uppercased())
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

/// The chosen countries as flags on a map. A click on a country adds it, or removes it again.
private struct CountryMap: View {
    let catalog: GeoCatalog
    @Binding var selected: Set<String>
    @State private var coordinates: [String: CLLocationCoordinate2D] = [:]
    @State private var position = MapCameraPosition.rect(.world)
    @State private var lookingUp = false
    @State private var notice: String?

    private var pins: [GeoCatalog.Country] {
        catalog.countries.filter { selected.contains($0.code) && coordinates[$0.code] != nil }
    }

    var body: some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: [.pan, .zoom]) {
                ForEach(pins) { country in
                    Annotation(country.name, coordinate: coordinates[country.code]!) {
                        Text(country.flag)
                            .font(.system(size: 26))
                            .padding(5)
                            .background(.regularMaterial, in: .circle)
                            .shadow(radius: 2)
                    }
                }
            }
            .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls { MapZoomStepper() }
            .onTapGesture { point in
                guard let coordinate = proxy.convert(point, from: .local) else { return }
                Task { await toggleCountry(at: coordinate) }
            }
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                if lookingUp { ProgressView().controlSize(.small) }
                if let notice { Text(notice) } else { Text("Click a country to add or remove it") }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: .capsule)
            .padding(12)
        }
        .overlay(alignment: .topLeading) {
            if !selected.isEmpty {
                Button("Show All", systemImage: "scope") { withAnimation { position = .automatic } }
                    .padding(10)
            }
        }
        .task(id: selected) { await locateSelected() }
    }

    private func toggleCountry(at coordinate: CLLocationCoordinate2D) async {
        lookingUp = true
        defer { lookingUp = false }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let code: String?
        if #available(macOS 26, *) {
            let request = MKReverseGeocodingRequest(location: location)
            let items = try? await request?.mapItems
            code = items?.first?.addressRepresentations?.region?.identifier.lowercased()
        } else {
            code = try? await CLGeocoder().reverseGeocodeLocation(location).first?.isoCountryCode?.lowercased()
        }
        guard let code,
              let country = catalog.country(code), !country.missing else {
            notice = String(localized: "No country there")
            try? await Task.sleep(for: .seconds(2))
            notice = nil
            return
        }
        coordinates[code] = coordinates[code] ?? coordinate
        if selected.contains(code) { selected.remove(code) } else { selected.insert(code) }
        notice = selected.contains(code) ? String(localized: "\(country.flag) \(country.name) added") : String(localized: "\(country.flag) \(country.name) removed")
        try? await Task.sleep(for: .seconds(2))
        notice = nil
    }

    /// Finds a point for each picked country by its English name.
    // ponytail: one lookup per country and MapKit limits how many run per minute,
    // so after a few dozen at once the rest show no flag; ship a centroid table if that matters.
    private func locateSelected() async {
        let missing = catalog.countries.filter { selected.contains($0.code) && coordinates[$0.code] == nil }
        for country in missing {
            guard !Task.isCancelled else { return }
            if #available(macOS 26, *) {
                let items = try? await MKGeocodingRequest(addressString: country.englishName)?.mapItems
                let match = items?.first { $0.addressRepresentations?.region?.identifier.lowercased() == country.code } ?? items?.first
                if let location = match?.location { coordinates[country.code] = location.coordinate }
            } else {
                let places = try? await CLGeocoder().geocodeAddressString(country.englishName)
                let match = places?.first { $0.isoCountryCode?.lowercased() == country.code } ?? places?.first
                if let location = match?.location { coordinates[country.code] = location.coordinate }
            }
        }
        if !missing.isEmpty { withAnimation { position = selected.isEmpty ? .rect(.world) : .automatic } }
    }
}

// MARK: - Services

struct ServicePicker: View {
    let catalog: GeoCatalog
    @Binding var selected: Set<String>
    @State private var search = ""

    struct Service: Identifiable {
        let name: String
        let symbol: String
        let rules: [String]
        var id: String { name }
    }

    static let popular: [Service] = [
        Service(name: "Google", symbol: "magnifyingglass", rules: ["geosite:google"]),
        Service(name: "YouTube", symbol: "play.rectangle.fill", rules: ["geosite:youtube"]),
        Service(name: "Telegram", symbol: "paperplane.fill", rules: ["geosite:telegram", "geoip:telegram"]),
        Service(name: "Instagram", symbol: "camera.fill", rules: ["geosite:instagram"]),
        Service(name: "WhatsApp", symbol: "phone.bubble.fill", rules: ["geosite:whatsapp"]),
        Service(name: "X (Twitter)", symbol: "bubble.left.fill", rules: ["geosite:twitter", "geosite:x", "geoip:twitter"]),
        Service(name: "Facebook", symbol: "person.2.fill", rules: ["geosite:facebook", "geoip:facebook"]),
        Service(name: "Netflix", symbol: "tv.fill", rules: ["geosite:netflix", "geoip:netflix"]),
        Service(name: "Spotify", symbol: "music.note", rules: ["geosite:spotify"]),
        Service(name: "TikTok", symbol: "music.note.tv.fill", rules: ["geosite:tiktok"]),
        Service(name: "Discord", symbol: "bubble.left.and.bubble.right.fill", rules: ["geosite:discord"]),
        Service(name: "Reddit", symbol: "text.bubble.fill", rules: ["geosite:reddit"]),
        Service(name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", rules: ["geosite:github"]),
        Service(name: "Apple", symbol: "apple.logo", rules: ["geosite:apple"]),
        Service(name: "Microsoft", symbol: "square.grid.2x2.fill", rules: ["geosite:microsoft"]),
        Service(name: "Amazon", symbol: "shippingbox.fill", rules: ["geosite:amazon"]),
        Service(name: "Steam", symbol: "gamecontroller.fill", rules: ["geosite:steam"]),
        Service(name: "OpenAI", symbol: "sparkles", rules: ["geosite:openai"]),
        Service(name: "Anthropic", symbol: "sparkle", rules: ["geosite:anthropic"]),
        Service(name: String(localized: "AI services"), symbol: "brain", rules: ["geosite:category-ai-!cn"]),
        Service(name: "Cloudflare", symbol: "cloud.fill", rules: ["geosite:cloudflare", "geoip:cloudflare"]),
        Service(name: String(localized: "Ads and trackers"), symbol: "eye.slash.fill", rules: ["geosite:category-ads-all"]),
        Service(name: String(localized: "Adult sites"), symbol: "18.circle.fill", rules: ["geosite:category-porn"]),
        Service(name: String(localized: "Games"), symbol: "dice.fill", rules: ["geosite:category-games"]),
        Service(name: String(localized: "Tor relays"), symbol: "network", rules: ["geoip:tor"]),
    ]

    private var services: [Service] {
        Self.popular.compactMap { service in
            let rules = service.rules.filter(catalog.lists.contains)
            return rules.isEmpty ? nil : Service(name: service.name, symbol: service.symbol, rules: rules)
        }
    }

    private var shownLists: [String] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? catalog.lists : catalog.lists.filter { $0.localizedStandardContains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Popular").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(services) { service in
                            ServiceTile(service: service, isOn: service.rules.allSatisfy(selected.contains)) { on in
                                if on { selected.formUnion(service.rules) } else { selected.subtract(service.rules) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            VStack(spacing: 0) {
                SearchField(prompt: "Search \(catalog.lists.count) lists", text: $search)
                    .padding(10)
                List(shownLists, id: \.self) { rule in
                    Toggle(rule, isOn: Binding(
                        get: { selected.contains(rule) },
                        set: { on in if on { selected.insert(rule) } else { selected.remove(rule) } }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.body.monospaced())
                }
                .listStyle(.inset)
                .overlay {
                    if shownLists.isEmpty { ContentUnavailableView.search(text: search) }
                }
                Text("geosite lists match names, geoip lists match addresses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .frame(width: 300)
        }
    }
}

private struct ServiceTile: View {
    let service: ServicePicker.Service
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Button { set(!isOn) } label: {
            HStack(spacing: 8) {
                Image(systemName: service.symbol)
                    .frame(width: 22)
                    .foregroundStyle(isOn ? Color.white : Color.accentColor)
                Text(service.name).lineLimit(1)
                Spacer(minLength: 0)
                if isOn { Image(systemName: "checkmark").font(.caption.bold()) }
            }
            .foregroundStyle(isOn ? .white : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isOn ? Color.accentColor : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(service.rules.joined(separator: ", "))
    }
}

/// A rounded search field like the system's, for panes that have no toolbar to put `.searchable` in.
struct SearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
    }
}
