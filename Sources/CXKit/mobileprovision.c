//
//  mobileprovision_utils.c
//  XKit
//
//  Created by Kabir Oberai on 05/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

#include <stdlib.h>
#include <string.h>
#include <openssl/pkcs7.h>
#include <openssl/bio.h>
#include "mobileprovision.h"

struct mobileprovision {
    PKCS7 *raw;
};

static mobileprovision_t mobileprovision_create(PKCS7 *raw) {
    mobileprovision_t profile = malloc(sizeof(struct mobileprovision));
    profile->raw = raw;
    return profile;
}

mobileprovision_t mobileprovision_create_from_data(const void *data, size_t len) {
    PKCS7 *raw = NULL;
    d2i_PKCS7(&raw, (const unsigned char **)&data, len);
    if (!raw) return NULL;

    return mobileprovision_create(raw);
}

void mobileprovision_free(mobileprovision_t profile) {
    PKCS7_free(profile->raw);
    free(profile);
}

void *mobileprovision_copy_data(mobileprovision_t profile, size_t *len) {
    unsigned char *data = NULL;
    size_t data_len = i2d_PKCS7(profile->raw, &data);
    if (data_len < 0) return NULL;
    *len = data_len;
    void *ret = malloc(data_len);
    memcpy(ret, data, data_len);
    OPENSSL_free(data);
    return ret;
}

const void *mobileprovision_get_digest(mobileprovision_t profile, size_t *len) {
    // we could dig into the struct ourselves instead but using the
    // documented API is better.
    BIO *digest_bio = PKCS7_dataDecode(profile->raw, NULL, NULL, NULL);
    if (!digest_bio) return NULL;
    char *data = NULL;
    long digest_len = BIO_get_mem_data(digest_bio, &data);
    // the mem pointer is owned by `profile`, not the bio
    BIO_free_all(digest_bio);
    if (len) *len = digest_len;
    return data;
}
