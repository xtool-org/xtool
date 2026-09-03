#ifndef PKCS12_HELPERS_H
#define PKCS12_HELPERS_H

#include <stddef.h>

#pragma clang assume_nonnull begin

void * _Nullable xtl_pkcs12_copy_private_key_pem(
    const void *p12_data,
    size_t p12_len,
    const char *password,
    size_t *pem_len
);

#pragma clang assume_nonnull end

#endif
