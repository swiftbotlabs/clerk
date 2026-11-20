#!/usr/bin/env python3
"""Testnet-only EIP-1193 backend for filming the approval page on the REAL Aevum testnet.
Forwards JSON-RPC to rpc-test.qday.info; answers eth_accounts / personal_sign / eth_sendTransaction with the
testnet owner key via cast. The key is read from KEYS and never printed. Listens on 127.0.0.1 only."""
import json, os, subprocess, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
RPC = 'https://rpc-test.qday.info'
KEY = json.load(open(os.environ['KEYS']))['owner']  # KEYS = path to the testnet key file (required)
PK, ADDR = KEY['private_key'], KEY['address']
def fwd(body):
    r = urllib.request.Request(RPC, data=json.dumps(body).encode(), headers={'content-type': 'application/json', 'user-agent': 'curl/8'})
    return json.load(urllib.request.urlopen(r, timeout=60))
def cast(*a):
    return subprocess.run(['cast', *a], capture_output=True, text=True, check=True).stdout.strip()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()
    def _cors(self):
        self.send_header('access-control-allow-origin', '*'); self.send_header('access-control-allow-headers', '*'); self.send_header('access-control-allow-methods', 'POST, OPTIONS')
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers['content-length'])))
        m, p = req['method'], req.get('params') or []
        try:
            if m in ('eth_accounts', 'eth_requestAccounts'): res = {'result': [ADDR]}
            elif m == 'personal_sign':
                res = {'result': cast('wallet', 'sign', '--private-key', PK, p[0])}
            elif m == 'eth_sendTransaction':
                t = p[0]
                cmd = ['send', '--legacy', '--async', '--private-key', PK, '--rpc-url', RPC]
                if t.get('gas'): cmd += ['--gas-limit', str(int(t['gas'], 16))]
                cmd += [t['to']]
                if t.get('data'): cmd += [t['data']]
                h = cast(*cmd); print('SENT', m, h, flush=True); res = {'result': h}
            else: res = fwd(req)
        except subprocess.CalledProcessError as e:
            res = {'error': {'code': -32000, 'message': (e.stderr or 'cast failed').replace(PK, '<k>')[:300]}}
        out = json.dumps({'jsonrpc': '2.0', 'id': req.get('id'), **{k: v for k, v in res.items() if k in ('result', 'error')}}).encode()
        self.send_response(200); self._cors(); self.send_header('content-type', 'application/json'); self.end_headers(); self.wfile.write(out)
HTTPServer(('127.0.0.1', 8556), H).serve_forever()
