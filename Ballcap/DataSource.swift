//
//  DataSource.swift
//  Pring
//
//  Created by 1amageek on 2017/10/06.
//  Copyright © 2017年 Stamp Inc. All rights reserved.
//
//  Contact us https://twitter.com/1amageek

import FirebaseFirestore
import FirebaseStorage


public enum DataSourceError: Error {
    case invalidReference
    case empty
    case timeout

    var description: String {
        switch self {
        case .invalidReference: return "The value you are trying to reference is invalid."
        case .empty: return "There was no value."
        case .timeout: return "DataSource fetch timed out."
        }
    }
}

public typealias Change = (deletions: [Int], insertions: [Int], modifications: [Int])

public enum CollectionChange {

    case initial

    case update(Change)

    case error(Error)

    init(change: Change?, error: Error?) {
        if let error: Error = error {
            self = .error(error)
            return
        }
        if let change: Change = change {
            self = .update(change)
            return
        }
        self = .initial
    }
}

/// DataSource class.
/// Observe at a Firebase DataSource location.
public final class DataSource<T: Object & DataRepresentable>: ExpressibleByArrayLiteral {

    public typealias ArrayLiteralElement = T

    public typealias Element = ArrayLiteralElement

    public typealias ChangeBlock = (QuerySnapshot?, CollectionChange) -> Void

    public typealias ParseBlock = (QuerySnapshot?, Element, @escaping ((Element) -> Void)) -> Void

    public typealias CompletedBlock = (QuerySnapshot?, [Element]) -> Void

    public typealias ErrorBlock = (QuerySnapshot?, DataSourceError) -> Void


    /// Objects held in the client
    public var documents: [Element] = []

    /// Count
    public var count: Int { return documents.count }

    /// True if we have the last Document of the data source
    public private(set) var isLast: Bool = false

    var completedBlocks: [CompletedBlock] = []

    /// Reference of element
    public private(set) var query: Query

    /// DataSource Option
    public private(set) var option: Option

    private let fetchQueue: DispatchQueue = DispatchQueue(label: "ballcap.datasource.fetch.queue")

    private var listenr: ListenerRegistration?

    /// Holds the Key previously sent to Firebase.
    private var previousLastKey: String?

    /// Block called when there is a change in DataSource
    private var changedBlock: ChangeBlock?

    private var parseBlock: ParseBlock?

    private var errorBlock: ErrorBlock?

    /// Applies the NSPredicate specified by option.
    private func filtered() -> [Element] {
        if let predicate: NSPredicate = self.option.predicate {
            return (self.documents as NSArray).filtered(using: predicate) as! [Element]
        }
        return self.documents
    }

    /**
     DataSource retrieves data from the referenced data. Change the acquisition of data by setting Options.
     If there is a change in the value, it will receive and notify you of the change.

     Handler blocks are called on the same thread that they were added on, and may only be added on threads which are
     currently within a run loop. Unless you are specifically creating and running a run loop on a background thread,
     this will normally only be the main thread.

     - parameter reference: Set DatabaseDeference
     - parameter options: DataSource Options
     - parameter block: A block which is called to process Firebase change evnet.
     */
    public init(reference: Query, option: Option = Option(), block: ChangeBlock? = nil) {
        self.query = reference
        self.option = option
        self.changedBlock = block
    }

    /// Initializing the DataSource
    public required convenience init(arrayLiteral documents: Element...) {
        self.init(documents)
    }

    /// Initializing the DataSource
    public init(_ documents: [Element]) {
        self.query = Element.query
        self.option = Option()
        self.documents = documents
    }

    /// Set the Block to receive the change of the DataSource.
    @discardableResult
    public func on(_ block: ChangeBlock?) -> Self {
        self.changedBlock = block
        return self
    }

    @discardableResult
    public func on(parse block: ParseBlock?) -> Self {
        self.parseBlock = block
        return self
    }

    @discardableResult
    public func onCompleted(_ block: CompletedBlock?) -> Self {
        if let block: CompletedBlock = block {
            self.completedBlocks.append(block)
        }
        return self
    }

    @discardableResult
    public func onError(_ block: ErrorBlock?) -> Self {
        self.errorBlock = block
        return self
    }

    /// Start monitoring data source.
    @discardableResult
    public func listen() -> Self {
        let changeBlock: ChangeBlock? = self.changedBlock
        let completedBlocks: [CompletedBlock] = self.completedBlocks
        var isFirst: Bool = true
        self.listenr = self.query.listen(includeMetadataChanges: self.option.includeMetadataChanges, listener: { [weak self] (snapshot, error) in
            guard let `self` = self else { return }
            guard let snapshot: QuerySnapshot = snapshot else {
                changeBlock?(nil, CollectionChange(change: nil, error: error))
                return
            }
            if isFirst {
                guard let lastSnapshot = snapshot.documents.last else {
                    // The collection is empty.
                    changeBlock?(snapshot, .initial)
                    completedBlocks.forEach({ block in
                        block(snapshot, self.documents)
                    })
                    return
                }
                if !snapshot.metadata.hasPendingWrites {
                    self.query = self.query.start(afterDocument: lastSnapshot)
                }
                self._operate(with: snapshot, isFirst: isFirst, error: error)
                isFirst = false
            } else {
                self._operate(with: snapshot, isFirst: isFirst, error: error)
            }
        })
        return self
    }

    /// Stop monitoring the data source.
    public func stop() {
        self.listenr?.remove()
    }

    private func _operate(with snapshot: QuerySnapshot?, isFirst: Bool, error: Error?) {
        let changeBlock: ChangeBlock? = self.changedBlock
        let parseBlock: ParseBlock? = self.parseBlock
        let completedBlocks: [CompletedBlock] = self.completedBlocks
        let errorBlock: ErrorBlock? = self.errorBlock

        func mainThreadCall(_ block: @escaping () -> Void) {
            if Thread.isMainThread {
                block()
            } else {
                DispatchQueue.main.async {
                    block()
                }
            }
        }

        guard let snapshot: QuerySnapshot = snapshot else {
            mainThreadCall {
                changeBlock?(nil, CollectionChange(change: nil, error: error))
                completedBlocks.forEach({ block in
                    block(nil, [])
                })
            }
            return
        }

        self.fetchQueue.async {
            let group: DispatchGroup = DispatchGroup()
            snapshot.documentChanges(includeMetadataChanges: self.option.includeMetadataChanges).forEach({ (change) in
                let id: String = change.document.documentID
                switch change.type {
                case .added:
                    guard self.option.listeningChangeTypes.contains(.added) else { return }
                    guard !self.documents.contains(where: { return $0.id == id}) else {
                        return
                    }
                    group.enter()
                    self.get(with: change, block: { (document, error) in
                        guard let document: Element = document else {
                            if !isFirst {
                                let error: Error = error ?? DataSourceError.invalidReference
                                let collectionChange: CollectionChange = CollectionChange.error(error)
                                mainThreadCall {
                                    changeBlock?(snapshot, collectionChange)
                                }
                            }
                            group.leave()
                            return
                        }
                        if let parseBlock: ParseBlock = parseBlock {
                            parseBlock(snapshot, document, { document in
                                self.documents.append(document)
                                self.documents = try! self.filtered().sorted(by: self.option.sortClosure)
                                if !isFirst {
                                    if let i: Int = self.documents.firstIndex(of: document) {
                                        mainThreadCall {
                                            changeBlock?(snapshot, CollectionChange(change: (deletions: [], insertions: [i], modifications: []), error: nil))
                                        }
                                    }
                                }
                                group.leave()
                            })
                        } else {
                            self.documents.append(document)
                            self.documents = try! self.filtered().sorted(by: self.option.sortClosure)
                            if !isFirst {
                                if let i: Int = self.documents.firstIndex(of: document) {
                                    mainThreadCall {
                                        changeBlock?(snapshot, CollectionChange(change: (deletions: [], insertions: [i], modifications: []), error: nil))
                                    }
                                }
                            }
                            group.leave()
                        }
                    })
                case .modified:
                    guard self.option.listeningChangeTypes.contains(.modified) else { return }
                    guard self.documents.contains(where: { return $0.id == id}) else {
                        return
                    }
                    group.enter()
                    self.get(with: change, block: { (document, error) in
                        guard let document: Element = document else {
                            let error: Error = error ?? DataSourceError.invalidReference
                            let collectionChange: CollectionChange = CollectionChange.error(error)
                            mainThreadCall {
                                changeBlock?(snapshot, collectionChange)
                            }
                            group.leave()
                            return
                        }
                        if let parseBlock: ParseBlock = parseBlock {
                            parseBlock(snapshot, document, { document in
                                if let i: Int = self.documents.index(of: id) {
                                    self.documents.remove(at: i)
                                    self.documents.insert(document, at: i)
                                }
                                self.documents = try! self.filtered().sorted(by: self.option.sortClosure)
                                if let i: Int = self.documents.index(of: document) {
                                    mainThreadCall {
                                        changeBlock?(snapshot, CollectionChange(change: (deletions: [], insertions: [], modifications: [i]), error: nil))
                                    }
                                }
                                group.leave()
                            })
                        } else {
                            if let i: Int = self.documents.index(of: id) {
                                self.documents.remove(at: i)
                                self.documents.insert(document, at: i)
                            }
                            self.documents = try! self.filtered().sorted(by: self.option.sortClosure)
                            if let i: Int = self.documents.index(of: document) {
                                mainThreadCall {
                                    changeBlock?(snapshot, CollectionChange(change: (deletions: [], insertions: [], modifications: [i]), error: nil))
                                }
                            }
                            group.leave()
                        }
                    })
                case .removed:
                    guard self.option.listeningChangeTypes.contains(.removed) else { return }
                    guard self.documents.contains(where: { return $0.id == id}) else {
                        return
                    }
                    group.enter()
                    if let i: Int = self.documents.index(of: id) {
                        self.documents.remove(at: i)
                        mainThreadCall {
                            changeBlock?(snapshot, CollectionChange(change: (deletions: [i], insertions: [], modifications: []), error: nil))
                        }
                        group.leave()
                    }
                @unknown default:
                    fatalError()
                }
            })
            group.notify(queue: DispatchQueue.main, execute: {
                if isFirst {
                    changeBlock?(snapshot, CollectionChange(change: nil, error: nil))
                }
                completedBlocks.forEach({ block in
                    block(snapshot, self.documents)
                })
            })
            switch group.wait(timeout: .now() + .seconds(self.option.timeout)) {
            case .success: break
            case .timedOut:
                let error: DataSourceError = DataSourceError.timeout
                mainThreadCall {
                    errorBlock?(snapshot, error)
                }
            }
        }
    }

    private func get(with change: DocumentChange, block: @escaping (Element?, Error?) -> Void) {
        if self.option.shouldFetchReference {
            let id: String = change.document.documentID
            Element.get(id: id) { (document, error) in
                if let error = error {
                    block(nil, error)
                    return
                }
                block(document, nil)
            }
        } else {
            guard let document: Element = Element(snapshot: change.document) else {
                block(nil, nil)
                return
            }
            DispatchQueue.main.async {
                block(document, nil)
            }
        }
    }

    @discardableResult
    public func get() -> Self {
        self.next()
        return self
    }

    /// Load the next data from the data source.
    /// - Parameters:
    ///     - block: It returns `isLast` as an argument.
    @discardableResult
    public func next(_ block: ((Bool) -> Void)? = nil) -> Self {
        self.query.get(completion: { (snapshot, error) in
            self._operate(with: snapshot, isFirst: false, error: error)
            guard let lastSnapshot = snapshot?.documents.last else {
                // The collection is empty.
                self.isLast = true
                block?(true)
                return
            }
            self.query = self.query.start(afterDocument: lastSnapshot)
            block?(false)
        })
        return self
    }

    // MARK: - deinit

    deinit {
        self.listenr?.remove()
    }
}

public extension DataSource {

    func add(document: Element) {
        let changeBlock: ChangeBlock? = self.changedBlock
        let parseBlock: ParseBlock? = self.parseBlock
        let completedBlocks: [CompletedBlock] = self.completedBlocks
        if let parseBlock: ParseBlock = parseBlock {
            parseBlock(nil, document, { document in
                self.documents.append(document)
                self.documents = try! self.filtered().sorted(by: self.option.sortClosure)
                if let i: Int = self.documents.firstIndex(of: document) {
                    changeBlock?(nil, CollectionChange(change: (deletions: [], insertions: [i], modifications: []), error: nil))
                }
            })
        } else {
            self.documents.append(document)
            self.documents = try! self.filtered().sorted(by: self.option.sortClosure)
            if let i: Int = self.documents.firstIndex(of: document) {
                changeBlock?(nil, CollectionChange(change: (deletions: [], insertions: [i], modifications: []), error: nil))
            }
        }
        completedBlocks.forEach({ block in
            block(nil, self.documents)
        })
    }

    func remove(document: Element) {
        let changeBlock: ChangeBlock? = self.changedBlock
        let completedBlocks: [CompletedBlock] = self.completedBlocks
        if let i: Int = self.documents.index(of: document.id) {
            self.documents.remove(at: i)
            changeBlock?(nil, CollectionChange(change: (deletions: [i], insertions: [], modifications: []), error: nil))
        }
        completedBlocks.forEach({ block in
            block(nil, self.documents)
        })
    }
}

public extension DataSource {
    /**
     Options class
     */
    final class Option {

        /// Fetch timeout
        public var timeout: Int = 10    // Default Timeout 10s

        ///
        public var includeMetadataChanges: Bool = true

        ///
        public var listeningChangeTypes: [DocumentChangeType] = [.added, .modified, .removed]

        /// Predicate
        public var predicate: NSPredicate?

        /// Sort
        public var sortClosure: (Element, Element) throws -> Bool = { l, r in
            return l.updatedAt > r.updatedAt
        }

        public var shouldFetchReference: Bool = false

        public init() { }
    }

}

public extension Array where Element: Documentable {

    var keys: [String] {
        return self.compactMap { return $0.id }
    }

    func index(of key: String) -> Int? {
        return self.keys.firstIndex(of: key)
    }

    func index(of document: Element) -> Int? {
        return self.keys.firstIndex(of: document.id)
    }
}

/**
 DataSource conforms to Collection
 */
extension DataSource: Collection {

    public var startIndex: Int {
        return 0
    }

    public var endIndex: Int {
        return self.documents.count
    }

    public func index(after i: Int) -> Int {
        return i + 1
    }

    public func index(where predicate: (Element) throws -> Bool) rethrows -> Int? {
        if self.documents.isEmpty { return nil }
        return try self.documents.firstIndex(where: predicate)
    }

    public func index(of element: Element) -> Int? {
        if self.documents.isEmpty { return nil }
        return self.documents.index(of: element.id)
    }

    public var first: Element? {
        if self.documents.isEmpty { return nil }
        return self.documents[startIndex]
    }

    public var last: Element? {
        if self.documents.isEmpty { return nil }
        return self.documents[endIndex - 1]
    }

    public func insert(_ newMember: Element) {
        if !self.documents.contains(newMember) {
            self.documents.append(newMember)
        }
    }

    public func remove(_ member: Element) {
        if let index: Int = self.documents.index(of: member) {
            self.documents.remove(at: index)
        }
    }

    public subscript(index: Int) -> Element {
        return self.documents[index]
    }

    public func forEach(_ body: (Element) throws -> Void) rethrows {
        return try self.documents.forEach(body)
    }
}
