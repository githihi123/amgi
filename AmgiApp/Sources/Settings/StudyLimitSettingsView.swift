import SwiftUI
import AnkiKit
import AnkiClients
import Dependencies

struct StudyLimitSettingsView: View {
    @Dependency(\.deckClient) private var deckClient

    @State private var decks: [DeckInfo] = []
    @State private var newCardsText = "\(StudyLimitPreferences.newCardsPerDay)"
    @State private var reviewsText = "\(StudyLimitPreferences.reviewsPerDay)"
    @State private var statusMessage: String?
    @State private var isApplying = false

    var body: some View {
        Form {
            Section("Daily Limits") {
                TextField("New cards per day", text: $newCardsText)
                    .keyboardType(.numberPad)
                TextField("Reviews per day", text: $reviewsText)
                    .keyboardType(.numberPad)

                Button {
                    Task { await applyToAllDecks() }
                } label: {
                    Label("Apply to All Decks", systemImage: "checkmark.circle")
                }
                .disabled(!hasValidLimits || isApplying)
            } footer: {
                Text("Saved limits are also applied automatically when opening a deck or starting review.")
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Decks") {
                if decks.isEmpty {
                    Text("No decks found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(decks) { deck in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(deck.name)
                                DeckCountsView(counts: deck.counts)
                            }
                            Spacer()
                            Button("Apply") {
                                Task { await apply(to: deck) }
                            }
                            .disabled(!hasValidLimits || isApplying)
                        }
                    }
                }
            }
        }
        .navigationTitle("Daily Card Limits")
        .task { await loadDecks() }
    }

    private var parsedNewLimit: UInt32? {
        parsedLimit(from: newCardsText)
    }

    private var parsedReviewLimit: UInt32? {
        parsedLimit(from: reviewsText)
    }

    private var hasValidLimits: Bool {
        parsedNewLimit != nil && parsedReviewLimit != nil
    }

    private func parsedLimit(from text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt32(trimmed), value > 0 else { return nil }
        return min(value, StudyLimitPreferences.maxLimit)
    }

    @MainActor
    private func loadDecks() async {
        do {
            decks = try deckClient.fetchAll()
        } catch {
            statusMessage = "Could not load decks: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func applyToAllDecks() async {
        guard let newLimit = parsedNewLimit, let reviewLimit = parsedReviewLimit else { return }
        isApplying = true
        defer { isApplying = false }

        StudyLimitPreferences.save(newCardsPerDay: newLimit, reviewsPerDay: reviewLimit)

        var failures: [String] = []
        for deck in decks {
            do {
                try deckClient.setDailyLimits(deck.id, newLimit, reviewLimit)
            } catch {
                failures.append(deck.name)
            }
        }

        await loadDecks()
        statusMessage = failures.isEmpty
            ? "Applied daily limits to \(decks.count) decks."
            : "Some decks failed: \(failures.joined(separator: ", "))"
    }

    @MainActor
    private func apply(to deck: DeckInfo) async {
        guard let newLimit = parsedNewLimit, let reviewLimit = parsedReviewLimit else { return }
        isApplying = true
        defer { isApplying = false }

        StudyLimitPreferences.save(newCardsPerDay: newLimit, reviewsPerDay: reviewLimit)

        do {
            try deckClient.setDailyLimits(deck.id, newLimit, reviewLimit)
            await loadDecks()
            statusMessage = "Applied daily limits to \(deck.name)."
        } catch {
            statusMessage = "Could not update \(deck.name): \(error.localizedDescription)"
        }
    }
}
