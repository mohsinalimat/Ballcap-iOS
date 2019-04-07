//
//  Batch.swift
//  Ballcap
//
//  Created by 1amageek on 2019/04/01.
//  Copyright © 2019 Stamp Inc. All rights reserved.
//

import FirebaseFirestore

public final class Batch {

    private var writeBatch: FirebaseFirestore.WriteBatch

    private var isCommitted: Bool = false

    public init(firestore: Firestore = Firestore.firestore()) {
        self.writeBatch = firestore.batch()
    }

    @discardableResult
    public func save<T: Documentable>(document: T, reference: DocumentReference? = nil) -> Self where T: DataRepresentable {
        if isCommitted {
            fatalError("Batch is already committed")
        }
        let reference: DocumentReference = reference ?? document.documentReference
        do {
            var data: [String: Any] = try Firestore.Encoder().encode(document.data!)
            if document.shouldIncludedInTimestamp {
                data["createdAt"] = FieldValue.serverTimestamp()
                data["updatedAt"] = FieldValue.serverTimestamp()
            }
            self.updateStorage[reference.path] = data
            self.writeBatch.setData(data, forDocument: reference)
            return self
        } catch let error {
            fatalError("Unable to encode data with Firestore encoder: \(error)")
        }
    }

    @discardableResult
    public func update<T: Documentable>(document: T, reference: DocumentReference? = nil) -> Self where T: DataRepresentable {
        if isCommitted {
            fatalError("Batch is already committed")
        }
        let reference: DocumentReference = reference ?? document.documentReference
        do {
            var data = try Firestore.Encoder().encode(document.data!)
            if document.shouldIncludedInTimestamp {
                data["updatedAt"] = FieldValue.serverTimestamp()
            }
            self.updateStorage[reference.path] = data
            self.writeBatch.updateData(data, forDocument: reference)
            return self
        } catch let error {
            fatalError("Unable to encode data with Firestore encoder: \(error)")
        }
    }

    @discardableResult
    public func delete<T: Documentable>(document: T) -> Self {
        if isCommitted {
            fatalError("Batch is already committed")
        }
        self.deleteStorage.append(document.documentReference.path)
        self.writeBatch.deleteDocument(document.documentReference)
        return self
    }

    public func commit(_ completion: ((Error?) -> Void)? = nil) {
        if isCommitted {
            fatalError("Batch is already committed")
        }
        self.writeBatch.commit {(error) in
            if let error = error {
                completion?(error)
                return
            }
            completion?(nil)
        }
    }
}

