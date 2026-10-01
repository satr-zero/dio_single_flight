/// Key used in `RequestOptions.extra` to mark a request that has already
/// been retried by the guard. Prevents infinite 401 → refresh → retry loops.
const String kRetryKey = '__dio_single_flight_retry__';

/// Key used in `RequestOptions.extra` storing the access token that was
/// actually sent with the request. The race guard compares it against the
/// provider's current token to detect whether a refresh already completed
/// after the request was dispatched.
const String kTokenKey = '__dio_single_flight_token__';
