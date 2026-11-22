@main struct OAuthLoginRegressionTests {
    @MainActor static func scenario(_ name: String, existing: Bool, social: Bool, reauthorizing: Bool = false,
                                    responseID: Int = 200, granted: String? = nil, success: Bool = true) async throws -> Bool {
        UserDefaults.standard.removeObject(forKey: AccountStore.accountsKey)
        UserDefaults.standard.removeObject(forKey: AccountStore.activeKey)
        CredentialStore.tokens = [:]
        if existing {
            try AccountStore.record(GitHubAccount(id: "100", login: "alice", avatarURL: nil, oauthScopes: ["read:user", "repo", "workflow"]))
            CredentialStore.tokens["100"] = "original-alice"
            AccountStore.activate("100")
        }
        let scopes = granted ?? (social ? "user,public_repo" : "read:user,public_repo")
        CompletionProtocol.reset([
            .init(#"{"device_code":"fixture-device","user_code":"AA-BB","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#),
            .init(#"{"access_token":"new-bob","token_type":"bearer","scope":"SCOPES"}"#.replacingOccurrences(of: "SCOPES", with: scopes)),
            .init(#"{"id":RESPONSE_ID,"login":"fixture-user","avatar_url":null}"#.replacingOccurrences(of: "RESPONSE_ID", with: String(responseID)), scopes: scopes)
        ])
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompletionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = GitHub(), controller = DeviceOAuthController(session: session, wait: { _ in })
        var completed = 0
        controller.start(clientID: "fixture-client", privateRepositories: false, writeProfile: social,
                         expectedAccountID: reauthorizing ? api.accountID : nil, api: api) { completed += 1 }
        let deadline = Date().addingTimeInterval(5)
        while controller.busy {
            precondition(Date() < deadline)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let requestScope = String(decoding: CompletionProtocol.captured[0].httpBody!, as: UTF8.self)
        let retainedCorrectly = reauthorizing ? requestScope.contains("workflow") : !requestScope.contains("workflow") && !requestScope.contains("%20repo")
        let saved = completed == 1 && AccountStore.activeID == String(responseID) && CredentialStore.tokens[String(responseID)] == "new-bob"
            && (!existing || responseID == 100 || CredentialStore.tokens["100"] == "original-alice")
        let rejected = completed == 0 && CredentialStore.tokens["200"] == nil
            && (!existing || CredentialStore.tokens["100"] == "original-alice")
            && !controller.message.contains("授权成功")
        let passed = retainedCorrectly && (success ? saved : rejected)
        print("\(passed ? "PASS" : "FAIL") \(name): \(controller.message)")
        return passed
    }
    @MainActor static func main() async throws {
        defer {
            UserDefaults.standard.removeObject(forKey: AccountStore.accountsKey)
            UserDefaults.standard.removeObject(forKey: AccountStore.activeKey)
        }
        var passed = true
        for existing in [false, true] {
            for social in [false, true] {
                let result = try await scenario("\(existing ? "second-account" : "first-login") social=\(social)", existing: existing, social: social)
                passed = result && passed
            }
        }
        for (name, id, grant, success) in [("same-account-reauthorize", 100, "user,repo,workflow", true),
                                          ("wrong-account-reauthorize", 200, "user,repo,workflow", false),
                                          ("narrowed-reauthorize", 100, "read:user,public_repo", false)] {
            passed = try await scenario(name, existing: true, social: true, reauthorizing: true, responseID: id, granted: grant, success: success) && passed
        }
        for existing in [false, true] {
            passed = try await scenario("missing-user-grant existing=\(existing)", existing: existing, social: true,
                                        granted: "read:user,public_repo", success: false) && passed
        }
        if !passed { exit(1) }
    }
}
