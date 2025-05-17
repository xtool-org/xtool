#include <stddef.h>
#include "version.h"

const char * _Nullable xtl_git_commit(void) {
    return XTL_GIT_COMMIT;
}

const char * _Nullable xtl_git_tag(void) {
    return XTL_GIT_TAG;
}
