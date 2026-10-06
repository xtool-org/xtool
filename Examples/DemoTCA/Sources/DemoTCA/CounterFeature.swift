import ComposableArchitecture

@Reducer
struct CounterFeature {
    @ObservableState
    struct State {
        var count = 0
    }

    enum Action {
        case appear
        case timerElapsed
    }

    @Dependency(\.continuousClock) var continuousClock

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .appear:
                return .run { [continuousClock] send in
                    try await continuousClock.sleep(for: .seconds(1))
                    await send(.timerElapsed)
                }
            case .timerElapsed:
                state.count += 1
                return .none
            }
        }
    }
}
