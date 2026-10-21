#!/usr/bin/env python3
"""HTTP proxy for opencode on Android.

Bun's io_uring networking doesn't work on Android, so we route all
outbound HTTP/HTTPS traffic through this Python proxy on localhost.

Supports three modes:

1. Fixed-target reverse proxy (legacy):
   Set PROXY_TARGET=https://example.com and requests to the proxy are
   forwarded to https://example.com<path>. This is what opencode's
   /v1/* API hits.

2. Absolute-URL forward proxy:
   If the request line contains an absolute URL (e.g. GET http://...),
   the proxy extracts the target and forwards. This is what most
   HTTP libraries do when HTTP_PROXY is set.

3. HTTP CONNECT tunnel (for HTTPS through HTTP_PROXY):
   The client sends CONNECT host:port HTTP/1.1, the proxy opens a
   raw TCP socket to the target, and pipes bytes both ways. Used
   by HTTP libraries for HTTPS targets when HTTP_PROXY is set.

Resource bounds (env, all optional):
   PROXY_PORT                   listen port (default 8080)
   PROXY_TARGET                 fixed target for mode 1
   PROXY_MAX_CONNECTIONS        concurrent connections (default 256)
   PROXY_IDLE_TIMEOUT           idle client socket timeout, seconds (120)
   PROXY_TUNNEL_IDLE_TIMEOUT    idle CONNECT tunnel timeout, seconds (300)
   PROXY_THREAD_STACK           thread stack bytes (524288)

Why these bounds exist — see the "Resource hygiene" notes inline. An
unbounded proxy on Android dies with SIGABRT once it runs out of address
space, which shows up to the user as constant "Unable to connect" errors.
"""

import http.server
import urllib.request
import ssl
import sys
import os
import socket
import select
import threading

TARGET = os.environ.get("PROXY_TARGET", "https://opencode.ai")
PORT = int(os.environ.get("PROXY_PORT", "8080"))
MAX_CONNECTIONS = int(os.environ.get("PROXY_MAX_CONNECTIONS", "256"))
IDLE_TIMEOUT = int(os.environ.get("PROXY_IDLE_TIMEOUT", "120"))
TUNNEL_IDLE_TIMEOUT = int(os.environ.get("PROXY_TUNNEL_IDLE_TIMEOUT", "300"))
THREAD_STACK_SIZE = int(os.environ.get("PROXY_THREAD_STACK", str(512 * 1024)))
REQUEST_QUEUE_SIZE = int(os.environ.get("PROXY_REQUEST_QUEUE", "128"))

ctx = ssl.create_default_context()

# ProxyHandler({}) disables proxying entirely for this opener.
#
# The wrapper exports HTTP_PROXY/HTTPS_PROXY=http://127.0.0.1:8080 and
# proxy.py inherits that environment. urllib's default ProxyHandler reads
# those variables, so without this the proxy's own outbound requests were
# routed back through the proxy itself — every forward doubled into a
# second connection and a second tunnel thread.
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=ctx),
)


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Bounds how long a handler thread may sit waiting for the next
    # request on an idle keep-alive socket. Without this, BaseHTTPRequestHandler
    # keeps the thread (and its socket fd) alive forever, and the thread
    # count — and with it the process address space — grows without limit.
    timeout = IDLE_TIMEOUT

    def _absolute_target(self):
        """Return absolute target URL if request line is an absolute URI."""
        if self.command == "CONNECT":
            return None
        path = self.path
        if path.startswith(("http://", "https://")):
            return path
        return None

    def _forward(self, url, body):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else None
        req = urllib.request.Request(url, data=body, method=self.command)
        for key, val in self.headers.items():
            if key.lower() not in ("host", "proxy-connection", "accept-encoding"):
                req.add_header(key, val)
        try:
            resp = opener.open(req, timeout=120)
            self.send_response(resp.status)
            for key, val in resp.getheaders():
                if key.lower() not in ("transfer-encoding",):
                    self.send_header(key, val)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for key, val in e.headers.items():
                if key.lower() not in ("transfer-encoding",):
                    self.send_header(key, val)
            self.send_header("Connection", "close")
            self.end_headers()
            if e.readable():
                self.wfile.write(e.read())
        except Exception as e:
            self.send_response(502)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(str(e).encode())

    def do_request(self):
        # The socket timeout only guards the idle wait for a request; clear
        # it while the request is being served so slow/long responses are
        # never cut short.
        self.connection.settimeout(None)
        target = self._absolute_target()
        if target and "127.0.0.1:8080" in target:
            from urllib.parse import urlparse

            parsed = urlparse(target)
            target = TARGET + parsed.path
            if parsed.query:
                target += "?" + parsed.query
        elif target:
            # Forward other absolute URLs as-is (e.g. localhost:11434 for Ollama)
            pass
        else:
            target = TARGET + self.path
        try:
            self._forward(target, None)
        finally:
            # We answered with "Connection: close"; make the handler agree,
            # otherwise it blocks forever waiting for another request on a
            # socket the client is about to drop.
            self.close_connection = True

    def do_CONNECT(self):
        try:
            host, port = self.path.split(":", 1)
            port = int(port)
        except ValueError:
            self.send_response(400)
            self.end_headers()
            self.close_connection = True
            return

        try:
            # 30s connect timeout only; the tunnel itself must be blocking —
            # a persisted timeout kills long-lived SSE inference streams.
            upstream = socket.create_connection((host, port), timeout=30)
            upstream.settimeout(None)
        except Exception as e:
            self.send_response(502)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(str(e).encode())
            self.close_connection = True
            return

        # No timeout on the client socket while tunnelling: a model may stay
        # silent for minutes mid-stream.
        self.connection.settimeout(None)
        self.send_response(200, "Connection Established")
        self.end_headers()

        sock = self.connection
        try:
            self._tunnel(sock, upstream)
        finally:
            # The tunnel is over; do not wait for another request on this
            # connection or the handler thread leaks.
            self.close_connection = True
            try:
                upstream.close()
            except OSError:
                pass

    def _tunnel(self, client, upstream):
        # poll(), not select(): select() is limited to FD_SETSIZE (1024)
        # descriptors and raises "filedescriptor out of range in select()"
        # once the process has more fds than that — which killed every
        # tunnel (and with it every API call) on a busy proxy.
        poller = select.poll()
        client_fd = client.fileno()
        upstream_fd = upstream.fileno()
        poller.register(client_fd, select.POLLIN)
        poller.register(upstream_fd, select.POLLIN)
        while True:
            try:
                events = poller.poll(TUNNEL_IDLE_TIMEOUT * 1000)
            except OSError:
                break
            if not events:
                # SSE streams can be silent >60s while the model thinks;
                # tear the tunnel down only after a long idle.
                break
            for fd, _event in events:
                if fd == client_fd:
                    src, dst = client, upstream
                elif fd == upstream_fd:
                    src, dst = upstream, client
                else:
                    continue
                try:
                    data = src.recv(65536)
                except OSError:
                    return
                if not data:
                    return
                try:
                    dst.sendall(data)
                except OSError:
                    return

    do_GET = do_request
    do_POST = do_request
    do_PUT = do_request
    do_PATCH = do_request
    do_DELETE = do_request

    def do_OPTIONS(self):
        self.do_request()

    def log_message(self, format, *args):
        pass


class ThreadedHTTPServer(http.server.HTTPServer):
    """Handle each request in a thread so CONNECT tunnels don't block."""

    daemon_threads = True
    allow_reuse_address = True

    # The default backlog of 5 makes the listen queue overflow under load;
    # the watchdog's health check then fails and it kills a healthy proxy.
    request_queue_size = REQUEST_QUEUE_SIZE

    def __init__(self, *args, **kwargs):
        self._conn_lock = threading.Lock()
        self._conn_count = 0
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        # Refuse new work instead of spawning a thread that cannot start:
        # a failed thread creation used to surface as "can't start new thread"
        # and, once the address space ran out, killed the whole process.
        with self._conn_lock:
            if self._conn_count >= MAX_CONNECTIONS:
                accepted = False
            else:
                self._conn_count += 1
                accepted = True
        if not accepted:
            self._reject(request)
            return

        t = threading.Thread(
            target=self._process_request, args=(request, client_address), daemon=True
        )
        try:
            t.start()
        except RuntimeError:
            with self._conn_lock:
                self._conn_count -= 1
            self._reject(request)

    def _reject(self, request):
        try:
            request.sendall(
                b"HTTP/1.1 503 Service Unavailable\r\n"
                b"Connection: close\r\n"
                b"Content-Length: 0\r\n\r\n"
            )
        except OSError:
            pass
        self.shutdown_request(request)

    def _process_request(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        finally:
            with self._conn_lock:
                self._conn_count -= 1
            self.shutdown_request(request)


if __name__ == "__main__":
    if os.environ.get("PROXY_DEBUG"):
        log_path = os.path.join(os.environ.get("TMPDIR", "/tmp"), "proxy.log")
        sys.stdout = open(log_path, "a")
        sys.stderr = sys.stdout
    else:
        sys.stdout = open(os.devnull, "w")
        sys.stderr = open(os.devnull, "w")

    # Python's default thread stack is 8 MB of virtual address space. With
    # hundreds of concurrent connections that is gigabytes of VmSize, and
    # Android kills the process with SIGABRT ("shadow stack ... mprotect
    # failed: Out of memory") once the address space runs out.
    try:
        threading.stack_size(THREAD_STACK_SIZE)
    except (ValueError, RuntimeError):
        pass

    server = ThreadedHTTPServer(("127.0.0.1", PORT), ProxyHandler)
    server.serve_forever()
