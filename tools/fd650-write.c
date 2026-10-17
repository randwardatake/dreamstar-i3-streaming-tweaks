/* Write 4 characters + colon flag to the Dreamstar i1 front-panel FD650 display, the way panelsrv does.
   usage: fd650-write TEXT [colon 0|1]   (stop panelsrv first) */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    const char *txt = argc > 1 ? argv[1] : "1234";
    int colon = argc > 2 ? argv[2][0] - '0' : 1;
    int fd = open("/dev/fd650_dev", O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    for (int i = 0; i < 3; i++) {
        unsigned char b[6] = {0};
        memcpy(b, txt, strnlen(txt, 4));
        b[4] = colon; b[5] = 8;
        ssize_t n = write(fd, b, 6);
        printf("write %d -> %zd\n", i, n);
        sleep(1);
    }
    close(fd);
    return 0;
}
