# Test-only TLS server: serves HTTP/1.1 200 "ok" with the given certificate chain on host:port.
# Usage: python3 -I tls-serve.py <cert.pem> <key.pem> <host> <port>
import http.server
import ssl
import sys

cert, key, host, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self):
        body = b"ok\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_PUT = _reply

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer((host, port), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
server.socket = ctx.wrap_socket(server.socket, server_side=True)
server.serve_forever()
