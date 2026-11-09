import Foundation

/// The contract folder (`contract/`, mirrored in mhub-android), found relative to this file
/// so both `swift test` and Xcode read the same fixtures as Android.
enum Fixtures {
    static let contract = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // MHubKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // MHubKit
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("contract")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: contract.appendingPathComponent("fixtures").appendingPathComponent(name))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}
