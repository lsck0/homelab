CC     ?= gcc
CFLAGS  = -O2 -Wall -Wextra -DEPOLL

server: main.c httpserver.h
	$(CC) $(CFLAGS) -o server main.c

clean:
	rm -f server
