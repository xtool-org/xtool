// ld64.lld trampoline for Windows (PE executable).
//
// Swift Build invokes `ld64.lld -r` to merge per-file Mach-O objects into one
// object for a module. lld does not support `-r` for Mach-O, so this wrapper
// intercepts that case and delegates to llvm-lib (-static), like the shell
// trampoline xtool ships for Linux. All other invocations are forwarded to
// the real linker at bin/orig/ld64.lld.exe.
//
// Build (on the macOS CI runner): x86_64-w64-mingw32-gcc -O2 -o ld64.lld.exe trampoline.c

#include <process.h>
#include <stdio.h>
#include <string.h>
#include <windows.h>

static char exe_dir[MAX_PATH];

static const char *find_arg_value(int argc, char **argv, const char *name) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], name) == 0) return argv[i + 1];
    }
    return NULL;
}

static int run(int argc, char **argv, const char *tool) {
    char path[MAX_PATH];
    snprintf(path, sizeof(path), "%s%s", exe_dir, tool);
    intptr_t rc = _spawnv(_P_WAIT, path, (const char *const *)argv);
    if (rc == -1) {
        fprintf(stderr, "ld64.lld trampoline: failed to run %s\n", path);
        return 127;
    }
    return (int)rc;
}

int main(int argc, char **argv) {
    GetModuleFileNameA(NULL, exe_dir, MAX_PATH);
    char *slash = strrchr(exe_dir, '\\');
    if (slash) {
        *(slash + 1) = '\0';
    } else {
        exe_dir[0] = '\0';
    }

    int reloc = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-r") == 0) reloc = 1;
    }

    if (reloc) {
        const char *filelist = find_arg_value(argc, argv, "-filelist");
        const char *dependency_info = find_arg_value(argc, argv, "-dependency_info");
        const char *output = find_arg_value(argc, argv, "-o");
        if (!filelist || !dependency_info || !output) {
            fprintf(stderr, "ld64.lld trampoline could not process arguments.\n");
            return 2;
        }
        char *newargv[] = {
            "llvm-lib.exe",
            "-static",
            "-filelist", (char *)filelist,
            "-dependency_info", (char *)dependency_info,
            "-o", (char *)output,
            NULL,
        };
        return run(7, newargv, "llvm-lib.exe");
    }

    argv[0] = "ld64.lld";
    return run(argc, argv, "orig\\ld64.lld.exe");
}
