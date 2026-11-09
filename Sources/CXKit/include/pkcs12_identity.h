#ifndef pkcs12_identity_h
#define pkcs12_identity_h

#include <stddef.h>

#pragma clang assume_nonnull begin

typedef enum {
    PKCS12_IDENTITY_OK = 0,
    PKCS12_IDENTITY_INVALID = 1,
    PKCS12_IDENTITY_BAD_PASSWORD = 2,
    PKCS12_IDENTITY_MISSING_CONTENT = 3,
} pkcs12_identity_status_t;

/// Extracts the leaf certificate (DER) and its private key (unencrypted PKCS#8 PEM)
/// from a PKCS#12 archive. On success both outputs are malloc'd and owned by the caller.
pkcs12_identity_status_t pkcs12_identity_extract(
    const void *data, size_t len,
    const char *password,
    void * _Nullable * _Nonnull cert_der, size_t *cert_len,
    void * _Nullable * _Nonnull key_pem, size_t *key_len
);

#pragma clang assume_nonnull end

#endif /* pkcs12_identity_h */
