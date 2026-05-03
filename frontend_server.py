#!/usr/bin/env python3
"""
Servidor de arquivos estáticos para o DataJus com Proxy reverso para o Backend.
Roteia as requisições /api e /escritorio para a porta 8000.
"""
import argparse
import sys
import os
import urllib.request
import urllib.error
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

class DataJusHandler(SimpleHTTPRequestHandler):
    backend_url = "http://127.0.0.1:8000"

    def do_GET(self):
        if self.path.startswith("/api/") or self.path.startswith("/escritorio") or self.path == "/health":
            self.proxy_request("GET")
        else:
            super().do_GET()

    def do_POST(self):
        if self.path.startswith("/api/") or self.path.startswith("/escritorio"):
            self.proxy_request("POST")
        else:
            self.send_error(405, "Method not allowed")

    def do_PUT(self):
        if self.path.startswith("/api/"):
            self.proxy_request("PUT")
        else:
            self.send_error(405, "Method not allowed")

    def do_DELETE(self):
        if self.path.startswith("/api/"):
            self.proxy_request("DELETE")
        else:
            self.send_error(405, "Method not allowed")

    def proxy_request(self, method):
        url = f"{self.backend_url}{self.path}"
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length) if content_length > 0 else None

        # Copiar headers da requisição original, removendo Host para evitar loops
        headers = {k: v for k, v in self.headers.items() if k.lower() != 'host'}
        
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        
        try:
            with urllib.request.urlopen(req) as response:
                self.send_response(response.status)
                for k, v in response.getheaders():
                    # Evitar duplicar headers de transferência ou cache que nós mesmos controlamos
                    if k.lower() not in ['content-length', 'transfer-encoding', 'content-encoding']:
                        self.send_header(k, v)
                
                resp_body = response.read()
                self.send_header('Content-Length', len(resp_body))
                self.end_headers()
                self.wfile.write(resp_body)
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            for k, v in e.headers.items():
                if k.lower() not in ['content-length', 'transfer-encoding']:
                    self.send_header(k, v)
            resp_body = e.read()
            self.send_header('Content-Length', len(resp_body))
            self.end_headers()
            self.wfile.write(resp_body)
        except Exception as e:
            self.send_error(502, f"Bad Gateway: {str(e)}")

    def end_headers(self):
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def log_message(self, fmt, *args):
        pass

    extensions_map = SimpleHTTPRequestHandler.extensions_map.copy()
    extensions_map.update({
        '.css': 'text/css',
        '.js': 'application/javascript',
        '.mjs': 'application/javascript',
        '.json': 'application/json',
        '.svg': 'image/svg+xml',
    })

def main():
    parser = argparse.ArgumentParser(description="DataJus server with API proxy")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5500)
    parser.add_argument("--directory", default="frontend")
    parser.add_argument("--backend", default="http://127.0.0.1:8000")
    args = parser.parse_args()

    os.chdir(args.directory)
    DataJusHandler.backend_url = args.backend.rstrip('/')

    server = ThreadingHTTPServer((args.host, args.port), DataJusHandler)
    print(f"[DataJus] Servidor unificado rodando em http://{args.host}:{args.port}/", flush=True)
    print(f"[DataJus] Proxy para backend ativo em {args.backend}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[DataJus] Servidor encerrado.", flush=True)
        sys.exit(0)

if __name__ == "__main__":
    main()
