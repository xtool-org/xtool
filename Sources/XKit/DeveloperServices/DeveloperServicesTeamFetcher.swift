import Foundation

private actor DeveloperServicesTeamFetcher {
    static let shared = DeveloperServicesTeamFetcher()

    private var cache: [DeveloperServicesTeam.ID: Task<DeveloperServicesTeam, Error>] = [:]

    private init() {}

    func teams(forXcodeLogin auth: XcodeAuthData) async throws -> DeveloperServicesTeam {
        let teamID = auth.teamID
        if let cached = cache[teamID] {
            return try await cached.value
        }
        let task = Task {
            let client = DeveloperServicesClient(authData: auth)
            let teams = try await client.send(DeveloperServicesListTeamsRequest())
            guard let team = teams.first(where: { $0.id == teamID })
                  else { throw Errors.teamNotFound(teamID) }
            return team
        }
        cache[auth.teamID] = task
        return try await task.value
    }

    enum Errors: LocalizedError {
        case teamNotFound(DeveloperServicesTeam.ID)

        public var errorDescription: String? {
            switch self {
            case .teamNotFound(let id):
                return id.rawValue.withCString {
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "add_app_operation.error.team_not_found",
                            value: "A team with the ID '%s' could not be found. Please select another team.",
                            comment: ""
                        ), $0
                    )
                }
            }
        }
    }
}

extension XcodeAuthData {
    public func team() async throws -> DeveloperServicesTeam {
        try await DeveloperServicesTeamFetcher.shared.teams(forXcodeLogin: self)
    }
}

extension DeveloperAPIAuthData {
    public func team() async throws -> DeveloperServicesTeam? {
        switch self {
        case .appStoreConnect: nil
        case .xcode(let auth): try await auth.team()
        }
    }
}
