// No-op codesign stub for Windows: Swift Build emits CodeSign tasks whose
// tool is taken from the platform manifest (CODESIGN=true). On Linux that is
// /bin/true; on Windows we ship this PE that always exits 0. We sign post-build.
int main(void) {
    return 0;
}
