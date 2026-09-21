#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <openssl/pkcs12.h>
#include <openssl/pem.h>
#if OPENSSL_VERSION_MAJOR >= 3
#include <openssl/provider.h>
#endif

#include "pkcs12.h"

#if OPENSSL_VERSION_MAJOR >= 3
static void configure_provider_search_path(void) {
    static const char *candidate_paths[] = {
        "/opt/homebrew/lib/ossl-modules",
        "/usr/local/lib/ossl-modules",
    };

    for (size_t i = 0; i < (sizeof(candidate_paths) / sizeof(candidate_paths[0])); i++) {
        const char *path = candidate_paths[i];
        if (access(path, R_OK) == 0) {
            OSSL_PROVIDER_set_default_search_path(NULL, path);
            return;
        }
    }
}
#endif

void *xtl_pkcs12_copy_private_key_pem(
    const void *p12_data,
    size_t p12_len,
    const char *password,
    size_t *pem_len
) {
    if (!p12_data || !pem_len) {
        return NULL;
    }

    *pem_len = 0;

    BIO *input = BIO_new_mem_buf(p12_data, (int)p12_len);
    if (!input) {
        return NULL;
    }

    PKCS12 *p12 = d2i_PKCS12_bio(input, NULL);
    BIO_free(input);
    if (!p12) {
        return NULL;
    }

    EVP_PKEY *private_key = NULL;
    X509 *certificate = NULL;
    STACK_OF(X509) *ca = NULL;

    int parsed = PKCS12_parse(p12, password, &private_key, &certificate, &ca);

#if OPENSSL_VERSION_MAJOR >= 3
    OSSL_PROVIDER *default_provider = NULL;
    OSSL_PROVIDER *legacy_provider = NULL;
    if (!parsed) {
        configure_provider_search_path();
        default_provider = OSSL_PROVIDER_load(NULL, "default");
        legacy_provider = OSSL_PROVIDER_load(NULL, "legacy");
        parsed = PKCS12_parse(p12, password, &private_key, &certificate, &ca);
    }
#endif

    PKCS12_free(p12);

    if (!parsed || !private_key) {
        if (certificate) {
            X509_free(certificate);
        }
        if (private_key) {
            EVP_PKEY_free(private_key);
        }
        if (ca) {
            sk_X509_pop_free(ca, X509_free);
        }
#if OPENSSL_VERSION_MAJOR >= 3
        if (legacy_provider) {
            OSSL_PROVIDER_unload(legacy_provider);
        }
        if (default_provider) {
            OSSL_PROVIDER_unload(default_provider);
        }
#endif
        return NULL;
    }

    BIO *output = BIO_new(BIO_s_mem());
    if (!output) {
        X509_free(certificate);
        EVP_PKEY_free(private_key);
        if (ca) {
            sk_X509_pop_free(ca, X509_free);
        }
#if OPENSSL_VERSION_MAJOR >= 3
        if (legacy_provider) {
            OSSL_PROVIDER_unload(legacy_provider);
        }
        if (default_provider) {
            OSSL_PROVIDER_unload(default_provider);
        }
#endif
        return NULL;
    }

    int wrote = PEM_write_bio_PrivateKey(output, private_key, NULL, NULL, 0, NULL, NULL);
    EVP_PKEY_free(private_key);
    X509_free(certificate);
    if (ca) {
        sk_X509_pop_free(ca, X509_free);
    }
#if OPENSSL_VERSION_MAJOR >= 3
    if (legacy_provider) {
        OSSL_PROVIDER_unload(legacy_provider);
    }
    if (default_provider) {
        OSSL_PROVIDER_unload(default_provider);
    }
#endif

    if (!wrote) {
        BIO_free(output);
        return NULL;
    }

    char *pem_data = NULL;
    long bio_len = BIO_get_mem_data(output, &pem_data);
    if (!pem_data || bio_len <= 0) {
        BIO_free(output);
        return NULL;
    }

    void *copied = malloc((size_t)bio_len);
    if (!copied) {
        BIO_free(output);
        return NULL;
    }
    memcpy(copied, pem_data, (size_t)bio_len);
    BIO_free(output);

    *pem_len = (size_t)bio_len;
    return copied;
}
