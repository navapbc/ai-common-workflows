"""Allowlist-enforcing egress proxy for the review sandbox.

Runs in the sidecar container, which straddles the sandbox's internal Docker
network (no route out) and the default bridge. The review container's only
path to the outside world is a CONNECT tunnel through this proxy, so the
allowlist below IS the sandbox's egress policy.

Design constraints, in order:
  1. Auditable — stdlib only, no dependencies, small enough to read in one
     sitting. Consumers are told to review this file before adopting.
  2. No TLS interception — CONNECT bytes are tunneled opaquely; the proxy
     sees only the requested host:port, never plaintext or certificates.
  3. Default deny — anything not matching ALLOWED_HOSTS is refused with 403,
     and every decision is logged (ALLOW/DENY host:port) for the audit trail.

Plain (non-CONNECT) HTTP is refused: every supported LLM/SCM endpoint is
HTTPS, and tunneling is the only mode that keeps rule 2 honest.

Configuration (environment):
  ALLOWED_HOSTS  comma/space-separated entries. "example.com" matches that
                 host exactly; ".example.com" or "*.example.com" matches its
                 subdomains (and the bare domain); "host:8443" pins a port
                 (entries without a port allow 443 only).
  PROXY_PORT     listen port (default 3128).
"""

import os
import socket
import socketserver
import sys
import threading

DEFAULT_PORT = 3128
CONNECT_TIMEOUT = 15
IDLE_TIMEOUT = 300
BUFFER = 65536


def log(decision, target):
    print(f"{decision} {target}", flush=True)


class Allowlist:
    def __init__(self, spec):
        self.entries = []
        for raw in spec.replace(",", " ").split():
            entry = raw.strip().lower()
            if not entry:
                continue
            host, _, port = entry.partition(":")
            self.entries.append((host, int(port) if port else 443))

    def permits(self, host, port):
        host = host.lower().rstrip(".")
        for allowed_host, allowed_port in self.entries:
            if port != allowed_port:
                continue
            if allowed_host.startswith("*."):
                suffix = allowed_host[1:]  # ".example.com"
                if host == allowed_host[2:] or host.endswith(suffix):
                    return True
            elif allowed_host.startswith("."):
                if host == allowed_host[1:] or host.endswith(allowed_host):
                    return True
            elif host == allowed_host:
                return True
        return False


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(CONNECT_TIMEOUT)
        try:
            request_line, headers = self._read_request_head()
        except (OSError, ValueError):
            return

        parts = request_line.split()
        if len(parts) != 3 or parts[0] != "CONNECT":
            method = parts[0] if parts else "?"
            log("DENY", f"{method} (non-CONNECT request refused)")
            self._respond(405, "Only CONNECT is supported by this proxy.")
            return

        host, _, port_str = parts[1].partition(":")
        try:
            port = int(port_str) if port_str else 443
        except ValueError:
            self._respond(400, "Bad CONNECT target.")
            return

        if not self.server.allowlist.permits(host, port):
            log("DENY", f"{host}:{port}")
            self._respond(403, f"Blocked by review-sandbox egress policy: {host}:{port} is not on the allowlist.")
            return

        try:
            upstream = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
        except OSError as e:
            log("DENY", f"{host}:{port} (upstream connect failed: {e})")
            self._respond(502, f"Upstream connection failed: {e}")
            return

        log("ALLOW", f"{host}:{port}")
        self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        self._tunnel(self.request, upstream)

    def _read_request_head(self):
        """Read up to the blank line ending the request head; return the
        request line. Header values are not needed for CONNECT."""
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.request.recv(BUFFER)
            if not chunk:
                raise ValueError("connection closed before request head")
            data += chunk
            if len(data) > 32 * 1024:
                raise ValueError("request head too large")
        head, _, _ = data.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        return lines[0], lines[1:]

    def _respond(self, code, message):
        reason = {400: "Bad Request", 403: "Forbidden", 405: "Method Not Allowed", 502: "Bad Gateway"}.get(code, "Error")
        body = message.encode()
        try:
            self.request.sendall(
                f"HTTP/1.1 {code} {reason}\r\n"
                f"Content-Type: text/plain\r\n"
                f"Content-Length: {len(body)}\r\n"
                f"Connection: close\r\n\r\n".encode() + body
            )
        except OSError:
            pass

    def _tunnel(self, client, upstream):
        """Relay bytes in both directions until either side closes."""
        client.settimeout(IDLE_TIMEOUT)
        upstream.settimeout(IDLE_TIMEOUT)

        def pump(src, dst):
            try:
                while True:
                    data = src.recv(BUFFER)
                    if not data:
                        break
                    dst.sendall(data)
            except OSError:
                pass
            finally:
                for s in (src, dst):
                    try:
                        s.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass

        t = threading.Thread(target=pump, args=(upstream, client), daemon=True)
        t.start()
        pump(client, upstream)
        t.join()
        upstream.close()


class ProxyServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    spec = os.environ.get("ALLOWED_HOSTS", "")
    if not spec.strip():
        print("ERROR: ALLOWED_HOSTS is empty — refusing to start an allow-nothing proxy silently.", file=sys.stderr)
        sys.exit(2)
    port = int(os.environ.get("PROXY_PORT", DEFAULT_PORT))

    server = ProxyServer(("0.0.0.0", port), ProxyHandler)
    server.allowlist = Allowlist(spec)
    print(f"allowlist proxy listening on :{port}; allowed: {spec}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
