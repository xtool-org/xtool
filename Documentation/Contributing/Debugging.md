# Debugging

## Environment variables

Some environment variables that help with debugging. Use these as e.g. `XTL_FOO=1 xtool ...`

### General

- `XTL_DEBUG_ERRORS`: If xtool terminates with an error, it normally prints a user-friendly error description. Set `XTL_DEBUG_ERRORS=1` for more verbose error logging.

### Disk

- `XTL_DEBUG_TMP`: Set to `1` to log details when xtool creates/destroys temporary directories.
- `XTL_TMPDIR`: Control the location where xtool stores temporary directories. We also respect `TMPDIR` and (on Linux) `XDG_CACHE_HOME`.

### Networking

- `XTL_DEV_LOG`: Regex. When making AppStoreConnect API requests, operation IDs that match the regex will log their response status and body. Set `XTL_DEV_LOG='.*'` to match all.
- `XTL_DISABLE_TLS_VALIDATION`: Set to `1` to disable all TLS validation on HTTP requests. Useful when using an MITM proxy to inspect API requests. Use sparingly, since disabling TLS is generally unsafe.
- `XTL_HTTP_PROXY`: non-Darwin only. Set to `<host>:<port>` to point the HTTP client to a proxy. e.g. `XTL_HTTP_PROXY=localhost:8080`. On Darwin (macOS/iOS), we instead use the system proxy configuration.
