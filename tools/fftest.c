#include <linux/input.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <string.h>
int main(int c, char **v) {
    int fd = open(v[1], O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    struct ff_effect e; memset(&e, 0, sizeof e);
    e.type = FF_RUMBLE; e.id = -1;
    e.u.rumble.strong_magnitude = 0xc000; e.u.rumble.weak_magnitude = 0xc000;
    e.replay.length = 1000;
    if (ioctl(fd, EVIOCSFF, &e) < 0) { perror("EVIOCSFF"); return 1; }
    struct input_event ev; memset(&ev, 0, sizeof ev);
    ev.type = EV_FF; ev.code = e.id; ev.value = 1;
    write(fd, &ev, sizeof ev);
    sleep(1); printf("ok id=%d\n", e.id); return 0;
}
