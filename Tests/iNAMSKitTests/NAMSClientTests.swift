import XCTest
@testable import iNAMSKit

/// Intercepts every request on the test URLSession. `handler` runs on
/// URLSession's loading queue; tests only set it before issuing requests.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data?) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            // URLSession converts httpBody to a stream by this point.
            let body = request.httpBodyStream.map { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }
            let (status, data) = try handler(request, body)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class NAMSClientTests: XCTestCase {
    private func makeClient(token: String? = "nams_test_key") -> NAMSClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return NAMSClient(config: .localDev, session: session) { token }
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
    }

    func testSearchMessagesSendsAuthAndWorkspaceHeadersAndDecodes() async throws {
        MockURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/v1/messages/search")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer nams_test_key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Workspace-Id"), "ws-1")
            let json = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any]
            XCTAssertEqual(json?["query"] as? String, "colorado")
            XCTAssertEqual(json?["limit"] as? Int, 5)
            let payload = """
            {"messages":[{"id":"m1","role":"user","content":"Colorado hike","createdAt":"2026-06-10T00:00:00Z","conversationId":"c1","score":0.91}],"searchType":"vector"}
            """
            return (200, Data(payload.utf8))
        }

        let client = makeClient()
        let result = try await client.searchMessages(query: "colorado", workspaceID: "ws-1", limit: 5)
        XCTAssertEqual(result.searchType, "vector")
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages[0].conversationId, "c1")
        XCTAssertEqual(result.messages[0].score, 0.91)
    }

    func testAddMessagePostsBody() async throws {
        MockURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.path, "/v1/conversations/conv-9/messages")
            let json = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: String]
            XCTAssertEqual(json, ["role": "user", "content": "note to self"])
            let payload = """
            {"id":"m9","conversationId":"conv-9","role":"user","content":"note to self"}
            """
            return (201, Data(payload.utf8))
        }

        let client = makeClient()
        let added = try await client.addMessage(
            conversationID: "conv-9", workspaceID: "ws-1", role: "user", content: "note to self"
        )
        XCTAssertEqual(added.id, "m9")
        XCTAssertEqual(added.conversationId, "conv-9")
    }

    func test401MapsToUnauthorized() async throws {
        MockURLProtocol.handler = { _, _ in (401, Data(#"{"error":"key expired"}"#.utf8)) }
        let client = makeClient()
        do {
            _ = try await client.listWorkspaces()
            XCTFail("expected unauthorized")
        } catch let error as NAMSError {
            XCTAssertEqual(error, .unauthorized)
            XCTAssertFalse(error.isTransient)
        }
    }

    func test429And503AreTransient() async throws {
        MockURLProtocol.handler = { _, _ in (429, Data()) }
        let client = makeClient()
        do {
            _ = try await client.listWorkspaces()
            XCTFail("expected rate limited")
        } catch let error as NAMSError {
            XCTAssertEqual(error, .rateLimited)
            XCTAssertTrue(error.isTransient)
        }

        MockURLProtocol.handler = { _, _ in (503, Data(#"{"error":"degraded"}"#.utf8)) }
        do {
            _ = try await client.listWorkspaces()
            XCTFail("expected server error")
        } catch let error as NAMSError {
            XCTAssertEqual(error, .server(status: 503, message: "degraded"))
            XCTAssertTrue(error.isTransient)
        }
    }

    func testMissingTokenFailsWithoutNetworkCall() async throws {
        MockURLProtocol.handler = { _, _ in
            XCTFail("no request should be issued without a token")
            return (500, Data())
        }
        let client = makeClient(token: nil)
        do {
            _ = try await client.listWorkspaces()
            XCTFail("expected unauthorized")
        } catch let error as NAMSError {
            XCTAssertEqual(error, .unauthorized)
        }
    }

    func testCreateAPIKeyUsesStoredKeyAndAuthBase() async throws {
        MockURLProtocol.handler = { request, body in
            XCTAssertEqual(request.url?.port, 8081, "api-key minting goes to nams-auth")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer nams_test_key")
            let json = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: String]
            XCTAssertEqual(json?["category"], "workspace")
            XCTAssertEqual(json?["workspaceId"], "ws-1")
            let payload = """
            {"id":"k1","key":"nams_fresh","label":"MCP – Claude Code","category":"workspace","workspaceId":"ws-1"}
            """
            return (201, Data(payload.utf8))
        }

        let client = makeClient()
        let created = try await client.createAPIKey(
            label: "MCP – Claude Code", category: "workspace", workspaceID: "ws-1"
        )
        XCTAssertEqual(created.key, "nams_fresh")
        XCTAssertEqual(created.workspaceId, "ws-1")
    }

    func testListAPIKeysUsesBearerOverrideAndDecodes() async throws {
        MockURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.port, 8081, "key listing goes to nams-auth")
            XCTAssertEqual(request.url?.path, "/v1/auth/api-keys")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"), "Bearer nams_pasted_key",
                "validation must use the pasted key, not the stored one"
            )
            let payload = """
            {"keys":[{"id":"abc123def456","label":"my admin key","createdAt":"2026-06-01T00:00:00Z","revokedAt":null,"expiresAt":"2026-08-30T12:00:00.123456Z","scopes":["workspace:admin"],"workspaceId":null}]}
            """
            return (200, Data(payload.utf8))
        }

        let client = makeClient()
        let keys = try await client.listAPIKeys(bearerOverride: "nams_pasted_key")
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys[0].id, "abc123def456")
        XCTAssertNotNil(keys[0].expiryDate, "fractional-second RFC3339 must parse")
    }

    func testErrorDescriptionsAreHumanReadable() {
        // Transport failures (status 0) carry the URLError text verbatim;
        // without LocalizedError this degraded to "NAMSError error 0."
        XCTAssertEqual(
            NAMSError.server(status: 0, message: "A server with the specified hostname could not be found.").localizedDescription,
            "A server with the specified hostname could not be found."
        )
        XCTAssertEqual(
            NAMSError.server(status: 503, message: "degraded").localizedDescription,
            "NAMS server error (503): degraded"
        )
        XCTAssertTrue(NAMSError.unauthorized.localizedDescription.contains("401"))
        XCTAssertTrue(NAMSError.forbidden.localizedDescription.contains("403"))
    }

    func testListAPIKeys403MapsToForbidden() async throws {
        MockURLProtocol.handler = { _, _ in
            (403, Data(#"{"error":"requires a user token or an admin api key"}"#.utf8))
        }
        let client = makeClient()
        do {
            _ = try await client.listAPIKeys(bearerOverride: "nams_workspace_key")
            XCTFail("expected forbidden")
        } catch let error as NAMSError {
            XCTAssertEqual(error, .forbidden, "workspace-bound keys are rejected by the list endpoint")
        }
    }
}

final class APIKeyFormatTests: XCTestCase {
    func testKeyIDParsesFromRawKey() {
        XCTAssertEqual(APIKeyFormat.keyID(fromRawKey: "nams_abc123def456_s3cr3tpart"), "abc123def456")
    }

    func testKeyIDToleratesUnderscoresInSecret() {
        XCTAssertEqual(APIKeyFormat.keyID(fromRawKey: "nams_abc123_extra_underscores"), "abc123")
    }

    func testKeyIDRejectsMalformedKeys() {
        XCTAssertNil(APIKeyFormat.keyID(fromRawKey: "sk-not-a-nams-key"))
        XCTAssertNil(APIKeyFormat.keyID(fromRawKey: "nams_nosecretseparator"))
        XCTAssertNil(APIKeyFormat.keyID(fromRawKey: "nams__emptyid"))
        XCTAssertNil(APIKeyFormat.keyID(fromRawKey: ""))
    }

    func testExpiryDateParsesWithAndWithoutFractionalSeconds() {
        func info(_ expiresAt: String?) -> APIKeyInfo {
            APIKeyInfo(
                id: "k", label: nil, createdAt: nil, revokedAt: nil,
                expiresAt: expiresAt, scopes: nil, workspaceId: nil
            )
        }
        XCTAssertNotNil(info("2026-08-30T12:00:00.123456Z").expiryDate)
        XCTAssertNotNil(info("2026-08-30T12:00:00Z").expiryDate)
        XCTAssertNil(info("not-a-date").expiryDate)
        XCTAssertNil(info(nil).expiryDate)
    }
}
