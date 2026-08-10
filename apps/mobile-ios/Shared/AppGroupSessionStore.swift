import Darwin
import Foundation
import PagePassCore

struct AppGroupSessionStore {
    enum StoreError: Error {
        case appGroupUnavailable
        case lockUnavailable
        case persistenceFailed
    }

    private let defaults: UserDefaults
    private let lockURL: URL
    private let key = "earnedTimeState.v1"

    static func live() throws -> AppGroupSessionStore {
        guard let defaults = UserDefaults(suiteName: PagePassScreenTime.appGroupID),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: PagePassScreenTime.appGroupID
              ) else {
            throw StoreError.appGroupUnavailable
        }
        return AppGroupSessionStore(
            defaults: defaults,
            lockURL: container.appendingPathComponent("earned-time-state.lock")
        )
    }

    init(defaults: UserDefaults, lockURL: URL) {
        self.defaults = defaults
        self.lockURL = lockURL
    }

    func load() throws -> EarnedTimeState {
        try withExclusiveLock {
            try loadUnlocked()
        }
    }

    func save(_ state: EarnedTimeState) throws {
        try withExclusiveLock {
            try saveUnlocked(state)
        }
    }

    @discardableResult
    func mutate(
        _ mutation: (inout EarnedTimeState) throws -> Void
    ) throws -> EarnedTimeState {
        try withExclusiveLock {
            var state = try loadUnlocked()
            try mutation(&state)
            try saveUnlocked(state)
            return state
        }
    }

    private func loadUnlocked() throws -> EarnedTimeState {
        guard let data = defaults.data(forKey: key) else {
            return EarnedTimeState()
        }
        return try JSONDecoder().decode(EarnedTimeState.self, from: data)
    }

    private func saveUnlocked(_ state: EarnedTimeState) throws {
        let data = try JSONEncoder().encode(state)
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw StoreError.persistenceFailed
        }
    }

    private func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw StoreError.lockUnavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw StoreError.lockUnavailable
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
