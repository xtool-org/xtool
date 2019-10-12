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

typedef struct mobileprovision *mobileprovision_t;

// MARK: - Lifecycle

/// create a profile from the given data
mobileprovision_t mobileprovision_create_from_data(const char *data, size_t len);

/// create a profile from the given file path
mobileprovision_t mobileprovision_create_from_path(const char *path);

/// free `profile`
void mobileprovision_free(mobileprovision_t profile);

// MARK: - Operations

char *mobileprovision_get_data(mobileprovision_t profile, size_t *len);

const char *mobileprovision_get_digest(mobileprovision_t profile, size_t *len);

#endif /* mobileprovision_h */
