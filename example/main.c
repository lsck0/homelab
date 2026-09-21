#define HTTPSERVER_IMPL
#include "httpserver.h"

static void handle_request(struct http_request_s *req) {
  struct http_response_s *res = http_response_init();
  http_response_status(res, 200);
  http_response_header(res, "Content-Type", "text/plain; charset=utf-8");
  http_response_body(res, "Hello, World!\n", 14);
  http_respond(req, res);
}

int main(void) {
  struct http_server_s *server = http_server_init(8000, handle_request);
  http_server_listen(server);
  return 0;
}
