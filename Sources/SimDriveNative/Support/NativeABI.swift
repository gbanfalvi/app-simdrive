import ABIBridge

extension NativeType {
    /// Resilient types, which CoreDevice passes by address.
    static func opaqueABIs(for types: [NativeSwiftType]) throws -> [NativeSwiftType: NativeType] {
        try Dictionary(uniqueKeysWithValues: types.map { ($0, try .opaque(named: $0.name)) })
    }

    /// `Foundation.Data`, or a struct that only wraps one. Data is @frozen, and CoreDevice passes its two words in
    /// integer registers.
    static func dataABI(_ type: NativeSwiftType) throws -> NativeType {
        try .structure(named: type.name, fields: [.uint64, .uint64])
    }
}
