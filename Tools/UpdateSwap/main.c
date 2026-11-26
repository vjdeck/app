#include <stdio.h>
#include <sys/stat.h>

// Exchange two complete bundles in one filesystem operation. A killed helper
// must never leave the installed path absent or pointing to a partial copy.
int main(int argc, char *argv[]) {
    struct stat staged, installed;
    if (argc != 3) {
        fprintf(stderr, "Usage: VJDeckUpdateSwap staged-app installed-app\n");
        return 64;
    }
    if (lstat(argv[1], &staged) != 0 || lstat(argv[2], &installed) != 0) {
        perror("Inspect update bundles");
        return 1;
    }
    if (!S_ISDIR(staged.st_mode) || !S_ISDIR(installed.st_mode)) {
        fprintf(stderr, "Update bundles must be directories, not symlinks\n");
        return 1;
    }
    if (renamex_np(argv[1], argv[2], RENAME_SWAP) != 0) {
        perror("Exchange update bundles");
        return 1;
    }
    return 0;
}
