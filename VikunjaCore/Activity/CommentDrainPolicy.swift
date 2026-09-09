import Foundation

/// What went wrong with a comment request, abstracted away from the transport.
///
/// `TaskStore` maps a concrete `VikunjaAPI.APIError` (or a bare transport
/// failure) onto one of these; everything downstream of that mapping is pure,
/// so the decision matrix can be tested. It could not be before: the
/// classification lived inline in `drainCommentOutbox`, and neither
/// `TaskStore.swift` nor `VikunjaAPI.swift` is compiled into `VeyrnCoreTests`.
/// That left the code deciding whether a user's comment is lost, duplicated or
/// retried forever as the only untestable part of the feature.
enum CommentFailureKind: Equatable {
    /// The server has no v2 comment endpoint at all.
    case notSupported
    /// 404 / 410 — the target is gone.
    case gone
    /// 429 — asked to slow down.
    case rateLimited
    /// 401 / 403.
    case authFailure
    /// Any other 4xx: validation and the like.
    case client4xx
    /// No HTTP answer: timeout, connection dropped, proxy 5xx. **Ambiguous** —
    /// the request may well have been applied server-side.
    case transport
}

/// Why an operation was given up on, so the app layer can pick the wording.
/// The policy stays free of user-facing strings, which live where localization
/// does.
enum CommentFailureReason: Equatable {
    /// A create that may already have posted. There is no idempotency key and
    /// no client correlation field on this API, so it must not be replayed
    /// automatically — the user has to check.
    case ambiguousCreate
    case notSupported
    /// Use the transport's own message.
    case server
}

enum CommentDrainOutcome: Equatable {
    /// Done — remove the operation. Also the right answer for deleting
    /// something already gone: the desired end state was reached.
    case acknowledge
    /// Try again later; counts against the retry ceiling.
    case retryable
    /// Give up and show the user. Never retried automatically.
    case permanent(CommentFailureReason)
    /// Stop the whole drain pass without blaming this operation. A throttle is
    /// a deferral, not a failed attempt, so it must not consume retry budget.
    case stopPass
}

enum CommentDrainPolicy {
    static func outcome(
        for failure: CommentFailureKind,
        kind: CommentOperationKind
    ) -> CommentDrainOutcome {
        switch failure {
        case .notSupported:
            // Retrying cannot help; the endpoint does not exist.
            return .permanent(.notSupported)

        case .gone:
            // A delete whose target is already gone succeeded in every sense
            // the user cares about. An update or create against a gone target
            // cannot be recovered.
            if case .delete = kind { return .acknowledge }
            return .permanent(.server)

        case .rateLimited:
            return .stopPass

        case .authFailure:
            // Recoverable in principle (a token can regain scope), so retryable
            // — but bounded by the ceiling, or a genuine 403 loops forever.
            return .retryable

        case .client4xx:
            return .permanent(.server)

        case .transport:
            // Update and delete are idempotent against a known comment id, so
            // replaying them converges. A create is not: the POST may have
            // landed, and replaying posts the comment twice.
            if case .create = kind { return .permanent(.ambiguousCreate) }
            return .retryable
        }
    }
}
