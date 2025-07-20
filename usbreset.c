#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <linux/usbdevice_fs.h>
#include <sys/ioctl.h>

int main(int argc, char **argv) {
  if (argc != 2) {
    printf("Usage: %s /dev/bus/usb/BBB/DDD\n", argv[0]);
    return 1;
  }
  int fd = open(argv[1], O_WRONLY);
  if (fd < 0) {
    perror("Error opening device");
    return 1;
  }
  printf("Resetting USB device %s\n", argv[1]);
  int rc = ioctl(fd, USBDEVFS_RESET, 0);
  if (rc < 0) {
    perror("Error in ioctl");
    return 1;
  }
  printf("Reset successful\n");
  close(fd);
  return 0;
}