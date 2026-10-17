/* read/modify sunxi display device config: dispcfg [bits] */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#define DISP_DEVICE_SET_CONFIG 0x14
#define DISP_DEVICE_GET_CONFIG 0x15
int main(int argc, char **argv) {
    unsigned int cfg[32]; unsigned long arg[4];
    int fd = open("/dev/disp", O_RDWR);
    if (fd < 0) { perror("open /dev/disp"); return 1; }
    memset(cfg, 0, sizeof cfg);
    arg[0] = 0; arg[1] = (unsigned long)cfg; arg[2] = 0; arg[3] = 0;
    int r = ioctl(fd, DISP_DEVICE_GET_CONFIG, arg);
    printf("get=%d type=%u mode=%u format=%u bits=%u eotf=%u cs=%u dvi=%u range=%u scan=%u ar=%u | raw:", r,
           cfg[0], cfg[1], cfg[2], cfg[3], cfg[4], cfg[5], cfg[6], cfg[7], cfg[8], cfg[9]);
    for (int i = 0; i < 16; i++) printf(" %x", cfg[i]);
    printf("\n");
    if (argc > 1 && r == 0) {
        cfg[3] = atoi(argv[1]);
        r = ioctl(fd, DISP_DEVICE_SET_CONFIG, arg);
        printf("set bits=%u -> %d\n", cfg[3], r);
    }
    close(fd);
    return 0;
}
