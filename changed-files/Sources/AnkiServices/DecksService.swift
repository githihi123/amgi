import AnkiBackend
import AnkiProto
public import AnkiKit
public import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct DecksService: Sendable {
    public var fetchAll: @Sendable () throws -> [DeckInfo]
    public var fetchTree: @Sendable () throws -> [DeckTreeNode]
    public var countsForDeck: @Sendable (_ deckId: Int64) throws -> DeckCounts
    public var setCurrentDeck: @Sendable (_ deckId: Int64) throws -> Void
    public var getCurrentDeck: @Sendable () throws -> DeckInfo
    public var createDeck: @Sendable (_ name: String) throws -> Int64
    public var renameDeck: @Sendable (_ deckId: Int64, _ name: String) throws -> Void
    public var removeDeck: @Sendable (_ deckId: Int64) throws -> Void
    public var rebuildFilteredDeck: @Sendable (_ deckId: Int64) throws -> Int
    public var emptyFilteredDeck: @Sendable (_ deckId: Int64) throws -> Void
    public var unlockDailyLimits: @Sendable (_ deckId: Int64) throws -> Void
}

extension DecksService: DependencyKey {
    public static let liveValue: Self = {
        @Dependency(\.ankiBackend) var backend
        return Self(
            fetchAll: {
                var treeReq = Anki_Decks_DeckTreeRequest()
                treeReq.now = Int64(Date().timeIntervalSince1970)
                do {
                    let tree: Anki_Decks_DeckTreeNode = try backend.invoke(
                        service: AnkiBackend.Service.decks,
                        method: AnkiBackend.DecksMethod.getDeckTree,
                        request: treeReq
                    )
                    return flattenDeckTree(tree).sorted { $0.name < $1.name }
                } catch {
                    let namesReq = Anki_Decks_GetDeckNamesRequest()
                    let namesResp: Anki_Decks_DeckNames = try backend.invoke(
                        service: AnkiBackend.Service.decks,
                        method: AnkiBackend.DecksMethod.getDeckNames,
                        request: namesReq
                    )
                    return namesResp.entries
                        .map { DeckInfo(id: $0.id, name: $0.name, counts: .zero) }
                        .sorted { $0.name < $1.name }
                }
            },
            fetchTree: {
                var req = Anki_Decks_DeckTreeRequest()
                req.now = Int64(Date().timeIntervalSince1970)
                let tree: Anki_Decks_DeckTreeNode = try backend.invoke(
                    service: AnkiBackend.Service.decks,
                    method: AnkiBackend.DecksMethod.getDeckTree,
                    request: req
                )
                return tree.children.map { mapDeckTreeNode($0) }
            },
            countsForDeck: { deckId in
                var treeReq = Anki_Decks_DeckTreeRequest()
                treeReq.now = Int64(Date().timeIntervalSince1970)
                do {
                    let tree: Anki_Decks_DeckTreeNode = try backend.invoke(
                        service: AnkiBackend.Service.decks,
                        method: AnkiBackend.DecksMethod.getDeckTree,
                        request: treeReq
                    )
                    if let node = findNode(in: tree, deckId: deckId) {
                        return DeckCounts(
                            newCount: Int(node.newCount),
                            learnCount: Int(node.learnCount),
                            reviewCount: Int(node.reviewCount)
                        )
                    }
                } catch {}
                return .zero
            },
            setCurrentDeck: { deckId in
                var req = Anki_Decks_DeckId()
                req.did = deckId
                try backend.callVoid(
                    service: AnkiBackend.Service.decks,
                    method: AnkiBackend.DecksMethod.setCurrentDeck,
                    request: req
                )
            },
            getCurrentDeck: {
                let deck: Anki_Decks_Deck = try backend.invoke(
                    service: AnkiBackend.Service.decks,
                    method: AnkiBackend.DecksMethod.getCurrentDeck,
                    request: Anki_Generic_Empty()
                )
                return DeckInfo(id: deck.id, name: deck.name)
            },
            createDeck: { name in
                // Fetch a default Deck proto with all fields populated, then set name and add.
                var deck: Anki_Decks_Deck = try backend.invoke(
                    service: AnkiBackend.Service.decks,
                    method: AnkiBackend.DecksMethod.newDeck
                )
                deck.name = name
                let resp: Anki_Collection_OpChangesWithId = try backend.invoke(
                    service: AnkiBackend.Service.decks,
                    method: AnkiBackend.DecksMethod.addDeck,
                    request: deck
                )
                return resp.id
            },
            renameDeck: { deckId, name in
                var req = Anki_Decks_RenameDeckRequest()
                req.deckID = deckId
                req.newName = name
                try backend.callVoid(
                    service: AnkiBackend.Service.decks,
                    method: AnkiBackend.DecksMethod.renameDeck,
                    request: req
                )
            },
            removeDeck: { deckId in
                var req = Anki_Decks_DeckIds()
                req.dids = [deckId]
                try backend.callVoid(
                    service: AnkiBackend.Service.decks,
                    method: AnkiBackend.DecksMethod.removeDecks,
                    request: req
                )
            },
            rebuildFilteredDeck: { deckId in
                var req = Anki_Decks_DeckId()
                req.did = deckId
                let resp: Anki_Collection_OpChangesWithCount = try backend.invoke(
                    service: AnkiBackend.Service.scheduler,
                    method: AnkiBackend.SchedulerMethod.rebuildFilteredDeck,
                    request: req
                )
                return Int(resp.count)
            },
            emptyFilteredDeck: { deckId in
                var req = Anki_Decks_DeckId()
                req.did = deckId
                try backend.callVoid(
                    service: AnkiBackend.Service.scheduler,
                    method: AnkiBackend.SchedulerMethod.emptyFilteredDeck,
                    request: req
                )
            },
            unlockDailyLimits: { deckId in
                try unlockDailyLimits(for: deckId, backend: backend)
            }
        )
    }()
}

extension DecksService: TestDependencyKey {
    public static let testValue = DecksService()
}

extension DependencyValues {
    public var decksService: DecksService {
        get { self[DecksService.self] }
        set { self[DecksService.self] = newValue }
    }
}

// MARK: - Helpers

private func flattenDeckTree(_ node: Anki_Decks_DeckTreeNode, parentPath: String = "") -> [DeckInfo] {
    var result: [DeckInfo] = []
    for child in node.children {
        let fullPath = parentPath.isEmpty ? child.name : "\(parentPath)::\(child.name)"
        result.append(DeckInfo(
            id: child.deckID,
            name: fullPath,
            counts: DeckCounts(
                newCount: Int(child.newCount),
                learnCount: Int(child.learnCount),
                reviewCount: Int(child.reviewCount)
            ),
            isFiltered: child.filtered
        ))
        result.append(contentsOf: flattenDeckTree(child, parentPath: fullPath))
    }
    return result
}

private func findNode(in node: Anki_Decks_DeckTreeNode, deckId: Int64) -> Anki_Decks_DeckTreeNode? {
    if node.deckID == deckId { return node }
    for child in node.children {
        if let found = findNode(in: child, deckId: deckId) { return found }
    }
    return nil
}

private func mapDeckTreeNode(_ node: Anki_Decks_DeckTreeNode, parentPath: String = "") -> DeckTreeNode {
    let fullPath = parentPath.isEmpty ? node.name : "\(parentPath)::\(node.name)"
    return DeckTreeNode(
        id: node.deckID,
        name: node.name,
        fullName: fullPath,
        counts: DeckCounts(
            newCount: Int(node.newCount),
            learnCount: Int(node.learnCount),
            reviewCount: Int(node.reviewCount)
        ),
        isFiltered: node.filtered,
        children: node.children.map { mapDeckTreeNode($0, parentPath: fullPath) }
    )
}

private let unlockedDailyLimit: UInt32 = 999_999

private func unlockDailyLimits(for deckId: Int64, backend: AnkiBackend) throws {
    var deckIdRequest = Anki_Decks_DeckId()
    deckIdRequest.did = deckId

    let currentOptions: Anki_DeckConfig_DeckConfigsForUpdate = try backend.invoke(
        service: AnkiBackend.Service.deckConfig,
        method: AnkiBackend.DeckConfigMethod.getDeckConfigsForUpdate,
        request: deckIdRequest
    )

    let currentConfigId = currentOptions.currentDeck.configID
    guard var config = currentOptions.allConfig
        .map(\.config)
        .first(where: { $0.id == currentConfigId }) ?? matchingDefaultConfig(
            in: currentOptions,
            configId: currentConfigId
        )
    else {
        return
    }

    var shouldUpdate = false
    var configValues = config.config
    if configValues.newPerDay < unlockedDailyLimit {
        configValues.newPerDay = unlockedDailyLimit
        shouldUpdate = true
    }
    if configValues.reviewsPerDay < unlockedDailyLimit {
        configValues.reviewsPerDay = unlockedDailyLimit
        shouldUpdate = true
    }
    config.config = configValues

    var limits = currentOptions.currentDeck.limits
    if !limits.hasNew || limits.new < unlockedDailyLimit {
        limits.new = unlockedDailyLimit
        shouldUpdate = true
    }
    if !limits.hasReview || limits.review < unlockedDailyLimit {
        limits.review = unlockedDailyLimit
        shouldUpdate = true
    }

    if !currentOptions.newCardsIgnoreReviewLimit || currentOptions.applyAllParentLimits {
        shouldUpdate = true
    }

    guard shouldUpdate else { return }

    var updateRequest = Anki_DeckConfig_UpdateDeckConfigsRequest()
    updateRequest.targetDeckID = deckId
    updateRequest.configs = [config]
    updateRequest.mode = .applyToChildren
    updateRequest.cardStateCustomizer = currentOptions.cardStateCustomizer
    updateRequest.limits = limits
    updateRequest.newCardsIgnoreReviewLimit = true
    updateRequest.fsrs = currentOptions.fsrs
    updateRequest.applyAllParentLimits = false
    updateRequest.fsrsReschedule = false
    updateRequest.fsrsHealthCheck = currentOptions.fsrsHealthCheck

    let _: Anki_Collection_OpChanges = try backend.invoke(
        service: AnkiBackend.Service.deckConfig,
        method: AnkiBackend.DeckConfigMethod.updateDeckConfigs,
        request: updateRequest
    )
}

private func matchingDefaultConfig(
    in options: Anki_DeckConfig_DeckConfigsForUpdate,
    configId: Int64
) -> Anki_DeckConfig_DeckConfig? {
    guard options.defaults.id == configId else { return nil }
    return options.defaults
}
