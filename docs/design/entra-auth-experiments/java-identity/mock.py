# HTTPS mock: Entra v2 token endpoint + OIDC metadata + App Service-style managed identity endpoint.
# Logs method, path and header *names* (never values) so the evidence never contains secrets.
import json, ssl, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
PORT = int(sys.argv[1]); TLS = sys.argv[2] == "tls"; BASE = f"{'https' if TLS else 'http'}://localhost:{PORT}"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _send(self, code, body):
        b = json.dumps(body).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _log(self, extra=""):
        print(f"[mock {PORT}] {self.command} {urlparse(self.path).path} q={sorted(parse_qs(urlparse(self.path).query))} hdrs={sorted(k.lower() for k in self.headers.keys())} {extra}", flush=True)
    def do_GET(self):
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path.endswith("/.well-known/openid-configuration"):
            tenant = u.path.split("/")[1]; self._log()
            return self._send(200, {"token_endpoint": f"{BASE}/{tenant}/oauth2/v2.0/token", "issuer": f"{BASE}/{tenant}/v2.0",
                                    "authorization_endpoint": f"{BASE}/{tenant}/oauth2/v2.0/authorize", "device_authorization_endpoint": f"{BASE}/{tenant}/oauth2/v2.0/devicecode"})
        if u.path == "/msi/token":
            ok = self.headers.get("X-IDENTITY-HEADER") == "fake-identity-header"
            self._log(f"identity-header-ok={ok} api-version={q.get('api-version')} client_id-present={'client_id' in q}")
            if not ok: return self._send(401, {"error": "bad header"})
            return self._send(200, {"access_token": "fake-mi-token", "expires_on": str(int(time.time()) + 3600), "resource": q.get("resource", [""])[0], "token_type": "Bearer"})
        if u.path == "/hello":
            self._log(); return self._send(200, {"hello": "from mock"})
        self._log("UNHANDLED"); self._send(404, {"error": "not found"})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); body = parse_qs(self.rfile.read(n).decode())
        self._log(f"form-keys={sorted(body)} grant_type={body.get('grant_type')}")
        if urlparse(self.path).path.endswith("/oauth2/v2.0/token"):
            return self._send(200, {"token_type": "Bearer", "expires_in": 3600, "ext_expires_in": 3600, "access_token": "fake-sp-token"})
        self._send(404, {"error": "not found"})
srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
if TLS:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(sys.argv[3], sys.argv[4]); srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
print(f"[mock {PORT}] listening {BASE}", flush=True); srv.serve_forever()
