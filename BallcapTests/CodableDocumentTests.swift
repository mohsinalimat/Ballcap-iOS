//
//  CodableDocumentTests.swift
//  BallcapTests
//
//  Created by 1amageek on 2019/03/27.
//  Copyright © 2019 Stamp Inc. All rights reserved.
//

import XCTest
import FirebaseFirestore
//@testable import Ballcap


class CodableDocumentTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = FirebaseTest.shared
    }

    // 
    func testModelCollectionReference() {
        struct Model: Codable, Documentable {}
        XCTAssertEqual(Model.collectionReference.path, "version/1/model")
    }

    func testModelDocumentReference() {
        struct Model: Codable, Documentable {}
        let document: Document<Model> = Document(id: "foo")
        XCTAssertEqual(document.documentReference.path, "version/1/model/foo")
    }

    func testInt() {
        struct Model: Codable, Equatable {
            let x: Int
        }
        let model = Model(x: 42)
        let dict = ["x": 42]
        assertRoundTrip(model: model, encoded: dict)
    }

    func testDocument() {
        struct Model: Codable, Equatable, Documentable {
            let number: Int = 0
            var string: String = "Ballcap"
        }
        let document: Document<Model> = Document()
        let dict: [String: Any] = ["number": 0, "string": "Ballcap"]
        print("!!!", document.data!)
        assertRoundTrip(model: document.data!, encoded: dict)
    }
}
