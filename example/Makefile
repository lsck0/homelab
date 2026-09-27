CC     ?= gcc
# httpserver.h never picks epoll on its own
CFLAGS  = -O2 -Wall -Wextra -DEPOLL

server: main.c httpserver.h
	$(CC) $(CFLAGS) -o server main.c

clean:
	rm -f server
