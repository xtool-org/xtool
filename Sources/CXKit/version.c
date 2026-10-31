#include "version.h"
#include <stddef.h>

const char *xtl_version(void) {
#ifdef XTOOL_VERSION
    return XTOOL_VERSION;
#else
    return "unversioned";
#endif
}

bool xtl_has_uncommitted_changes(void) {
#ifndef XTOOL_VERSION
    return true;
#else
#ifdef XTOOL_HAS_UNCOMMITTED_CHANGES
    return XTOOL_HAS_UNCOMMITTED_CHANGES != 0;
#else
    return false;
#endif
#endif
}
