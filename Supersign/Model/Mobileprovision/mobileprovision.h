//
//  mobileprovision_utils.h
//  supersign
//
//  Created by Kabir Oberai on 05/07/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

#ifndef mobileprovision_h
#define mobileprovision_h

#include <stdio.h>

#pragma clang assume_nonnull begin

typedef struct mobileprovision *mobileprovision_t;

// MARK: - Lifecycle

/// create a profile from the given data
_Nullable mobileprovision_t mobileprovision_create_from_data(const void *data, size_t len);

/// create a profile from the given file path
_Nullable mobileprovision_t mobileprovision_create_from_path(const char *path);

/// free `profile`
void mobileprovision_free(mobileprovision_t profile);

// MARK: - Operations

void * _Nullable mobileprovision_get_data(mobileprovision_t profile, size_t *len);

const void * _Nullable mobileprovision_get_digest(mobileprovision_t profile, size_t *len);

#pragma clang assume_nonnull end

#endif /* mobileprovision_h */
