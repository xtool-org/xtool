import DeveloperAPI

/// An `AsyncSequence` that unfolds a paginated DeveloperAPI request.
///
/// Some Developer API GET requests are paginated. Each response contains
/// a `links.next` field that points to the next page. This API allows you to
/// consume all pages as an `AsyncSequence`. For example, you can
/// enumerate all devices with
///
/// ```swift
/// let pages = DeveloperAPIPages {
///   try await client.devicesGetCollection().ok.body.json
/// } next: {
///   $0.links.next
/// }
/// for try await page in pages {
///   print(page.data)
/// }
/// ```
public struct DeveloperAPIPages<Page>: AsyncSequence {
    // inspired by PagedRequest from
    // https://github.com/AvdLee/appstoreconnect-swift-sdk

    public var request: @Sendable () async throws -> Page
    public var getNext: @Sendable (Page) -> String?

    public init(
        request: @escaping @Sendable () async throws -> Page,
        next getNext: @escaping @Sendable (Page) -> String?
    ) {
        self.request = request
        self.getNext = getNext
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(request: request, getNext: getNext)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate enum State {
            case initial
            case hasNext(String)
            case end
        }

        fileprivate let request: @Sendable () async throws -> Page
        fileprivate let getNext: @Sendable (Page) -> String?

        fileprivate var state: State = .initial

        public mutating func next() async throws -> Page? {
            let cursor: String?

            switch state {
            case .initial:
                cursor = nil
            case .hasNext(let next):
                cursor = next
            case .end:
                return nil
            }

            let page = try await DeveloperAPIClient.withNextLink(cursor) {
                try await request()
            }

            if let next = getNext(page) {
                state = .hasNext(next)
            } else {
                state = .end
            }

            return page
        }
    }
}
