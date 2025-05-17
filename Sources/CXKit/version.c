#include "version.h"

const char *xtl_version(void) {
#ifdef XTOOL_VERSION
    return XTOOL_VERSION;
#else
    return "unversioned";
#endif
}
