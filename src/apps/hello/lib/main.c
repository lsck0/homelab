#define HTTPSERVER_IMPL
#include "httpserver.h"

#include <string.h>

#define BODY "Hello, World!\n"
/* app.nix targetPort and the Dockerfile EXPOSE */
#define HELLO_PORT 8000

static int request_is_head(struct http_request_s* req) {
    struct http_string_s method = http_request_method(req);
    return method.len == 4 && memcmp(method.buf, "HEAD", 4) == 0;
}

static void handle_request(struct http_request_s* req) {
    struct http_response_s* res = http_response_init();
    http_response_status(res, 200);
    http_response_header(res, "Content-Type", "text/plain; charset=utf-8");
    if (!request_is_head(req)) http_response_body(res, BODY, sizeof(BODY) - 1);
    http_respond(req, res);
}

int main(void) {
    struct http_server_s* server = http_server_init(HELLO_PORT, handle_request);
    http_server_listen(server);
    return 0;
}
