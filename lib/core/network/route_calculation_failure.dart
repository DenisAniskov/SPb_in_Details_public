enum RouteFailureKind {
  pedestrianUnavailable,
  serviceUnavailable,
  nativeBudgetExceeded,
  requestLimitReached,
  invalidResponse,
  noMeaningfulRoute,
  mixedNativeConstraints,
}

/// Safe, typed failures. Native SDK errors and route titles are never displayed.
class RouteCalculationFailure implements Exception {
  final RouteFailureKind kind;
  const RouteCalculationFailure(this.kind);
}

/// Counts actual native point-to-point requests across one bounded walk build.
class NativeWalkRequestBudget {
  final int maximumRequests;
  int _requests = 0;
  NativeWalkRequestBudget(this.maximumRequests);
  int get requests => _requests;
  int get remaining => maximumRequests - _requests;

  void consume() {
    if (remaining <= 0) {
      throw const RouteCalculationFailure(RouteFailureKind.requestLimitReached);
    }
    ++_requests;
  }
}
