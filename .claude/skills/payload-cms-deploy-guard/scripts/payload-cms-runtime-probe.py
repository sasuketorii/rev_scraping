#!/usr/bin/env python3
"""Small read-only Payload CMS runtime probe.

Use only against your own staging or production domain. It performs OPTIONS/GET
checks and one GraphQL introspection POST unless --no-graphql is set.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Dict, Optional


@dataclass
class Result:
    name: str
    method: str
    url: str
    status: Optional[int]
    finding: str
    severity: str
    evidence: str


def request(method: str, url: str, body: Optional[bytes] = None, headers: Optional[Dict[str, str]] = None, timeout: int = 10):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            data = res.read(4096)
            return res.status, dict(res.headers), data
    except urllib.error.HTTPError as e:
        try:
            data = e.read(4096)
        except Exception:
            data = b""
        return e.code, dict(e.headers), data
    except Exception as e:
        return None, {}, str(e).encode()


def base_url(raw: str) -> str:
    u = raw.rstrip('/')
    if not urllib.parse.urlparse(u).scheme:
        u = 'https://' + u
    return u


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('base_url', help='https://example.com')
    ap.add_argument('--api-path', default='/api')
    ap.add_argument('--origin', default='https://evil.example', help='Origin used for CORS preflight test')
    ap.add_argument('--no-graphql', action='store_true')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    base = base_url(args.base_url)
    api = base + args.api_path.rstrip('/')
    results = []

    # CORS preflight against API root.
    st, h, data = request('OPTIONS', api, headers={
        'Origin': args.origin,
        'Access-Control-Request-Method': 'GET',
        'Access-Control-Request-Headers': 'content-type,authorization',
    })
    acao = h.get('Access-Control-Allow-Origin', '')
    accred = h.get('Access-Control-Allow-Credentials', '')
    sev = 'high' if acao == '*' or (acao == args.origin and accred.lower() == 'true') else 'info'
    results.append(Result('cors-preflight', 'OPTIONS', api, st, 'CORS response to untrusted origin', sev, f'ACAO={acao!r} ACCred={accred!r}'))

    # Payload API root/health-ish path.
    for path in [api, api + '/graphql']:
        st, h, data = request('GET', path)
        exposed = 'enabled/reachable' if st and st < 500 else 'not reachable or server error'
        sev = 'medium' if path.endswith('/graphql') and st and st < 500 else 'info'
        results.append(Result('endpoint-reachability', 'GET', path, st, exposed, sev, data[:160].decode('utf-8', 'replace').replace('\n', ' ')))

    if not args.no_graphql:
        q = json.dumps({'query': 'query IntrospectionQuery { __schema { queryType { name } mutationType { name } types { name } } }'}).encode()
        st, h, data = request('POST', api + '/graphql', body=q, headers={'Content-Type': 'application/json'})
        text = data.decode('utf-8', 'replace')
        introspection = '__schema' in text or 'types' in text and 'queryType' in text
        sev = 'high' if st == 200 and introspection else ('medium' if st == 200 else 'info')
        results.append(Result('graphql-introspection', 'POST', api + '/graphql', st, 'GraphQL introspection reachable' if introspection else 'GraphQL introspection not confirmed', sev, text[:300].replace('\n', ' ')))

    if args.json:
        print(json.dumps([r.__dict__ for r in results], indent=2, ensure_ascii=False))
    else:
        print('| severity | check | method | status | finding | evidence |')
        print('|---|---|---:|---:|---|---|')
        for r in results:
            ev = r.evidence.replace('|', '\\|')
            print(f'| {r.severity} | {r.name} | {r.method} | {r.status} | {r.finding} | `{ev}` |')

    return 1 if any(r.severity in {'high'} for r in results) else 0


if __name__ == '__main__':
    sys.exit(main())
