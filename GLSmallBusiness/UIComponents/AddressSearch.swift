//
//  AddressSearch.swift
//  GLSmallBusiness
//
//  Created by Gold Life LLC on 6/23/26.
//
//  Maps-style address typeahead. `AddressSearchButton` drops a "Search for an address" row into a
//  form's Address section; tapping it opens `AddressSearchSheet`, where live MapKit suggestions appear
//  as you type and one tap fills street / city / state / ZIP. The manual fields stay editable.
//
//  No location permission is needed — MKLocalSearchCompleter queries by text, not the device's location.
//

import SwiftUI
import MapKit

/// The address pieces a chosen search result fills into a form.
struct AddressSearchResult {
    var street1: String
    var city: String
    var state: String
    var postalCode: String

    nonisolated init(fullAddress: String) {
        let parsed = Self.parse(fullAddress: fullAddress)
        street1 = parsed.street
        city = parsed.city
        state = parsed.state
        postalCode = parsed.postalCode
    }

    /// Split a MapKit `fullAddress` ("123 Main St, Springfield, FL 32308, United States") into form
    /// fields. iOS 26 retired `MKPlacemark`'s structured properties, so we parse the formatted string:
    /// work from the end (country → "STATE ZIP" → city → whatever's left is the street) so a multi-part
    /// street like "123 Main St, Apt 4" stays intact. Pure + testable.
    nonisolated static func parse(fullAddress: String) -> (street: String, city: String, state: String, postalCode: String) {
        var parts = fullAddress
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Trailing country, if MapKit included one.
        if let last = parts.last,
           ["united states", "usa", "united states of america"].contains(last.lowercased()) {
            parts.removeLast()
        }

        // "FL 32308" / "FL 32308-1234" / "FL" / a bare "32308" normally sits last.
        var state = ""
        var postalCode = ""
        if let last = parts.last {
            let tokens = last.split(separator: " ").map(String.init)
            if let first = tokens.first, first.count == 2, first.allSatisfy(\.isLetter) {
                state = first.uppercased()
                postalCode = tokens.dropFirst().first { $0.contains(where: \.isNumber) } ?? ""
                parts.removeLast()
            } else if tokens.count == 1, last.allSatisfy(\.isNumber) {
                postalCode = last
                parts.removeLast()
            }
        }

        // Of what remains, the last piece is the city and everything before it is the street.
        let city = parts.count >= 2 ? parts.removeLast() : ""
        return (parts.joined(separator: ", "), city, state, postalCode)
    }
}

/// Live address suggestions from MapKit, updated as the query changes.
@MainActor
@Observable
final class AddressCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var suggestions: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = .address
        completer.delegate = self
    }

    func update(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            suggestions = []
        } else {
            completer.queryFragment = trimmed
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }
}

/// A form row that opens the address search sheet and writes the chosen address into the bound fields.
struct AddressSearchButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var street1: String
    @Binding var city: String
    @Binding var state: String
    @Binding var postalCode: String
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Label("Search for an address", systemImage: "magnifyingglass")
        }
        .sheet(isPresented: $showing) {
            AddressSearchSheet { result in
                street1 = result.street1
                city = result.city
                state = result.state
                postalCode = result.postalCode
            }
            .glAppearance(colorScheme)
        }
    }
}

struct AddressSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var completer = AddressCompleter()
    @State private var query = ""
    @State private var lookupFailed = false
    @FocusState private var searchFocused: Bool
    let onSelect: (AddressSearchResult) -> Void

    private var gold: Color { GLColor.gold.render(in: colorScheme) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                suggestions
            }
            .background { GLColor.backgroundPrimary.render(in: colorScheme).ignoresSafeArea() }
            .navigationTitle("Find Address")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
            .onAppear { searchFocused = true }
            .onChange(of: query) { _, newValue in completer.update(newValue) }
            .alert("Couldn’t load that address", isPresented: $lookupFailed) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Something went wrong getting that address. Pick another, or type it in by hand.")
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Street address", text: $query)
                .focused($searchFocused)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .glCardBackground()
        .padding()
    }

    @ViewBuilder
    private var suggestions: some View {
        if trimmedQuery.isEmpty {
            ContentUnavailableView("Search for an address", systemImage: "mappin.and.ellipse",
                                   description: Text("Start typing a street address to see suggestions."))
        } else if completer.suggestions.isEmpty {
            ContentUnavailableView("No matches", systemImage: "magnifyingglass",
                                   description: Text("No addresses found yet — keep typing."))
        } else {
            List(completer.suggestions, id: \.self) { suggestion in
                Button { resolve(suggestion) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title)
                        if !suggestion.subtitle.isEmpty {
                            Text(suggestion.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
        }
    }

    private func resolve(_ suggestion: MKLocalSearchCompletion) {
        searchFocused = false
        Task {
            do {
                let response = try await MKLocalSearch(request: .init(completion: suggestion)).start()
                // iOS 26 retired MKMapItem.placemark; read the formatted address and parse it.
                guard let fullAddress = response.mapItems.first?.address?.fullAddress else {
                    lookupFailed = true; return
                }
                onSelect(AddressSearchResult(fullAddress: fullAddress))
                dismiss()
            } catch {
                lookupFailed = true
            }
        }
    }
}
