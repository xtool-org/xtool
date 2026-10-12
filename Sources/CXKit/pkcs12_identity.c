#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <openssl/bio.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/provider.h>
#include <openssl/x509.h>
#include "pkcs12_identity.h"

static pthread_once_t providers_once = PTHREAD_ONCE_INIT;

static void load_providers_once(void) {
    // archives exported by older keychains use RC2/3DES, which OpenSSL 3 only
    // provides through the legacy provider. It's fine if it isn't available.
    OSSL_PROVIDER_load(NULL, "default");
    OSSL_PROVIDER_load(NULL, "legacy");
}

static void load_providers(void) {
    // loading providers concurrently races with PKCS12_parse on other threads
    // (seen as a parse that succeeds without a key or certificate), so do it once
    pthread_once(&providers_once, load_providers_once);
}

pkcs12_identity_status_t pkcs12_identity_extract(
    const void *data, size_t len,
    const char *password,
    void **cert_der, size_t *cert_len,
    void **key_pem, size_t *key_len
) {
    *cert_der = NULL;
    *key_pem = NULL;
    *cert_len = 0;
    *key_len = 0;

    load_providers();
    ERR_clear_error();

    pkcs12_identity_status_t status = PKCS12_IDENTITY_INVALID;
    PKCS12 *p12 = NULL;
    EVP_PKEY *pkey = NULL;
    X509 *cert = NULL;
    STACK_OF(X509) *ca = NULL;
    BIO *mem = NULL;

    const unsigned char *cursor = data;
    p12 = d2i_PKCS12(NULL, &cursor, (long)len);
    if (!p12) goto done;

    if (!PKCS12_parse(p12, password, &pkey, &cert, &ca)) {
        unsigned long err = ERR_peek_last_error();
        if (ERR_GET_LIB(err) == ERR_LIB_PKCS12 && ERR_GET_REASON(err) == PKCS12_R_MAC_VERIFY_FAILURE) {
            status = PKCS12_IDENTITY_BAD_PASSWORD;
        }
        goto done;
    }
    if (!pkey || !cert) {
        status = PKCS12_IDENTITY_MISSING_CONTENT;
        goto done;
    }

    unsigned char *der = NULL;
    int der_len = i2d_X509(cert, &der);
    if (der_len <= 0) goto done;

    mem = BIO_new(BIO_s_mem());
    if (!mem || !PEM_write_bio_PKCS8PrivateKey(mem, pkey, NULL, NULL, 0, NULL, NULL)) {
        OPENSSL_free(der);
        goto done;
    }
    char *pem = NULL;
    long pem_len = BIO_get_mem_data(mem, &pem);

    *cert_der = malloc((size_t)der_len);
    *key_pem = malloc((size_t)pem_len);
    if (!*cert_der || !*key_pem) {
        free(*cert_der);
        free(*key_pem);
        *cert_der = NULL;
        *key_pem = NULL;
        OPENSSL_free(der);
        goto done;
    }
    memcpy(*cert_der, der, (size_t)der_len);
    memcpy(*key_pem, pem, (size_t)pem_len);
    *cert_len = (size_t)der_len;
    *key_len = (size_t)pem_len;
    OPENSSL_free(der);
    status = PKCS12_IDENTITY_OK;

done:
    BIO_free_all(mem);
    sk_X509_pop_free(ca, X509_free);
    X509_free(cert);
    EVP_PKEY_free(pkey);
    PKCS12_free(p12);
    return status;
}
