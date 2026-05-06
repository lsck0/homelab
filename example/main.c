#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <signal.h>

#define PORT 8000
#define BACKLOG 128
#define BUF 4096

static const char RESPONSE[] =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/plain; charset=utf-8\r\n"
    "Content-Length: 14\r\n"
    "Connection: close\r\n"
    "\r\n"
    "Hello, World!\n";

int main(void) {
    signal(SIGPIPE, SIG_IGN);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return 1; }

    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_addr.s_addr = 0,
        .sin_port = __builtin_bswap16(PORT),
    };

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { perror("bind"); return 1; }
    if (listen(fd, BACKLOG) < 0) { perror("listen"); return 1; }

    printf("listening on :%d\n", PORT);
    fflush(stdout);

    char buf[BUF];
    for (;;) {
        int client = accept(fd, NULL, NULL);
        if (client < 0) continue;
        read(client, buf, sizeof(buf) - 1);
        write(client, RESPONSE, sizeof(RESPONSE) - 1);
        close(client);
    }
}
