CC     ?= gcc
# -DEPOLL: httpserver.h gates its typedefs behind EPOLL or KQUEUE and detects
# neither on its own, so without this every build dies on "unknown type name
# 'epoll_cb_t'". The container is Linux, so epoll is the right one.
CFLAGS  = -O2 -Wall -Wextra -DEPOLL

server: main.c httpserver.h
	$(CC) $(CFLAGS) -o server main.c

clean:
	rm -f server
