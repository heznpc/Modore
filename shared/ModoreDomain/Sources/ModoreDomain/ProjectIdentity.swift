import Foundation

public enum EvidenceContractError: Error, Equatable {
    case emptyIdentity
    case invalidMethodBasis
    case invalidSnapshot
}

/// A comparison key supplied by a platform adapter, not a verified filesystem target.
public struct ProjectIdentity: Hashable, Codable, Sendable {
    public let comparisonKey: String

    public init(comparisonKey: String) throws {
        guard !comparisonKey.isEmpty else { throw EvidenceContractError.emptyIdentity }
        self.comparisonKey = comparisonKey
    }

    private enum CodingKeys: String, CodingKey { case comparisonKey }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(comparisonKey: values.decode(String.self, forKey: .comparisonKey))
    }
}

public struct AssetIdentity: Hashable, Codable, Sendable {
    public let namespace: String
    public let key: String

    public init(namespace: String, key: String) throws {
        guard !namespace.isEmpty, !key.isEmpty else { throw EvidenceContractError.emptyIdentity }
        self.namespace = namespace
        self.key = key
    }

    private enum CodingKeys: String, CodingKey { case namespace, key }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(namespace: values.decode(String.self, forKey: .namespace),
                      key: values.decode(String.self, forKey: .key))
    }
}
