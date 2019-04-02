//
//  ServerTimestamp.swift
//  Ballcap
//
//  Created by 1amageek on 2019/04/02.
//  Copyright © 2019 Stamp Inc. All rights reserved.
//

import FirebaseFirestore

public enum ServerTimestamp: Codable, Equatable, Hashable {
    case pending
    case resolved(Timestamp)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if (container.decodeNil()) {
            self = .pending
        } else {
            let value = try container.decode(Timestamp.self)
            self = .resolved(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch (self) {
        case .pending:
            try container.encode(FieldValue.serverTimestamp())
            break
        case .resolved(value: let value):
            try container.encode(value)
            break
        }
    }
}
