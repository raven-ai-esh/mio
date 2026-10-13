#!/usr/bin/env python3
"""Exercise packaged MCP -> Unix IPC -> SQLite using a fresh synthetic profile."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--executable', type=Path, required=True)
parser.add_argument('--receipt', type=Path, required=True)
args = parser.parse_args()
executable = args.executable.resolve(strict=True)
state = Path(tempfile.mkdtemp(prefix='mio-catalog-', dir='/tmp'))
env = dict(os.environ, MIO_DATA_DIRECTORY=str(state))
env.pop('MIO_PROFILE_TOKEN', None)
passed = []

def check(condition, name):
    if not condition:
        raise AssertionError(name)
    passed.append(name)

def rpc(method, params=None):
    result = subprocess.run([str(executable), '--rpc', method, json.dumps(params or {})],
                            env=env, capture_output=True, text=True, timeout=20, check=True)
    return json.loads(result.stdout)

def mcp(token, calls):
    requests = [{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
        'protocolVersion': '2025-06-18', 'clientInfo': {'name': 'Mio catalog acceptance', 'version': '1'}}},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}]
    requests += [{'jsonrpc': '2.0', 'id': i+3, 'method': 'tools/call',
                  'params': {'name': name, 'arguments': params}} for i, (name, params) in enumerate(calls)]
    result = subprocess.run([str(executable), '--mcp'], env=dict(env, MIO_PROFILE_TOKEN=token),
                            input=''.join(json.dumps(r)+'\n' for r in requests),
                            capture_output=True, text=True, timeout=30, check=True)
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    check(len(replies) == len(requests), 'stdio replies match requests; no stdout diagnostics')
    check([t['name'] for t in replies[1]['result']['tools']] == ['search', 'read', 'capture', 'revise', 'link'], 'five tools retained')
    schema = next(t['inputSchema'] for t in replies[1]['result']['tools'] if t['name'] == 'read')
    check('spaces' in schema['properties']['kind']['enum'] and schema['required'] == ['kind'], 'advertised catalog without required id')
    check('read(kind=spaces)' in replies[0]['result']['instructions'], 'initial instructions explain discovery')
    return replies[2:]

def content(reply):
    result = reply['result']
    check(not result.get('isError', False), 'tool returned successful result')
    return result['structuredContent']

def denial(reply, code):
    check(reply['result'].get('isError') is True and reply['result']['structuredContent']['code'] == code,
          'explicit tool denial: '+code)

log = (state/'service.log').open('w')
service = subprocess.Popen([str(executable), '--background'], env=env,
                           stdin=subprocess.DEVNULL, stdout=log, stderr=log)
try:
    deadline = time.monotonic()+10
    while not (state/'Runtime/bridge.sock').exists():
        if service.poll() is not None or time.monotonic() > deadline:
            raise RuntimeError('Isolated owner did not start; see '+str(state/'service.log'))
        time.sleep(0.05)
    names = ['Home', 'Read only', 'Write shared', 'Duplicate', 'Duplicate', 'HIDDEN_NAME', 'DELETED_NAME']
    spaces = [rpc('space.create', {'name': name})['id'] for name in names]
    home, ro, rw, dup1, dup2, hidden, deleted = spaces
    def mount(source, target, access):
        return rpc('connection.create', {'from_space_id': source, 'to_space_id': target, 'access': access})['id']
    mount(home, ro, 'read'); grant = mount(home, rw, 'write')
    mount(home, dup1, 'read'); mount(home, dup2, 'write'); mount(ro, hidden, 'write'); mount(home, deleted, 'write')
    rpc('space.delete', {'space_id': deleted})
    profile = rpc('profile.create', {'name': 'Catalog acceptance', 'space_id': home})
    token = profile['token']
    note = rpc('note.create', {'space_id': rw, 'title': 'Catalog needle', 'body': 'CATALOG_EXACT_FACT'})
    replies = mcp(token, [('read', {'kind': 'spaces'}), ('read', {'kind': 'spaces', 'limit': 2}),
                         ('read', {'kind': 'spaces', 'offset': 2, 'limit': 2}),
                         ('read', {'kind': 'spaces', 'offset': 4, 'limit': 2}),
                         ('read', {'kind': 'note'}), ('read', {'kind': 'spaces', 'id': 'invalid'}),
                         ('read', {'kind': 'note', 'id': note['id']})])
    catalog = content(replies[0]); rows = catalog['spaces']
    check({r['id'] for r in rows} == {home, ro, rw, dup1, dup2}, 'only home and live direct mounts exposed')
    check(catalog['default_space_id'] == home and catalog['total_count'] == 5, 'default and authorized total')
    check(sum(r['name'] == 'Duplicate' for r in rows) == 2, 'duplicate names retain distinct IDs')
    check(all(r['can_read'] for r in rows) and not next(r for r in rows if r['id'] == ro)['can_write'], 'read-only permission reported')
    check(next(r for r in rows if r['id'] == rw)['can_write'], 'write permission reported')
    check(not any(x in json.dumps(catalog) for x in ['HIDDEN_NAME', 'DELETED_NAME', token, 'token_hash']), 'no hidden metadata or credentials')
    pages = [content(r) for r in replies[1:4]]
    check([r for p in pages for r in p['spaces']] == rows and [p['next_offset'] for p in pages] == [2,4,None], 'stable pagination covers authorized rows exactly')
    check(replies[4]['error']['code'] == -32602, 'old note read still requires id')
    denial(replies[5], 'invalid_params')
    check(content(replies[6])['body'] == 'CATALOG_EXACT_FACT', 'old note read unchanged')

    chosen = next(r for r in rows if r['name'] == 'Write shared')['id']
    replies = mcp(token, [('search', {'query': 'CATALOG_EXACT_FACT', 'scope': 'notes', 'space_ids': [chosen]}),
                         ('capture', {'space_id': chosen, 'title': 'Catalog capture', 'body': 'Scoped write', 'idempotency_key': 'catalog-write'}),
                         ('capture', {'space_id': ro, 'title': 'Forbidden write', 'body': 'Must not persist', 'idempotency_key': 'catalog-readonly'}),
                         ('read', {'kind': 'note', 'id': 'unavailable'}),
                         ('search', {'query': 'CATALOG_EXACT_FACT', 'space_ids': [hidden]})])
    hits = content(replies[0])['results']
    check(bool(hits) and all(h['space_id'] == chosen for h in hits), 'name -> ID -> scoped search')
    captured = content(replies[1])
    check(captured['note']['space_id'] == chosen and captured['receipt']['status'] == 'local_committed', 'name -> ID -> scoped capture committed')
    check(rpc('read', {'kind': 'note', 'id': captured['id']})['body'] == 'Scoped write', 'captured note persists in downstream store')
    denial(replies[2], 'forbidden'); denial(replies[3], 'forbidden')
    check(content(replies[4])['semantic_state'] == 'empty_scope', 'hidden scope cannot expand access')
    snapshot = rpc('snapshot')
    check(not any(n['title'] == 'Forbidden write' for n in snapshot['notes']), 'denied capture has no downstream write')
    events = [e for e in snapshot['events'] if e.get('kind') == 'memory_operation' and e.get('request',{}).get('kind') == 'spaces' and e.get('phase') == 'end' and e.get('outcome') == 'success']
    check(bool(events) and all(set(e['required_space_ids']) == {home,ro,rw,dup1,dup2} for e in events), 'catalog history retains complete ACL dependencies')
    check(any(e['result_count'] == 5 and len(e['result_refs']) == 5 for e in events), 'catalog history records returned space refs and count')

    rpc('space.rename', {'space_id': rw, 'name': 'Renamed shared'})
    rpc('connection.delete', {'connection_id': grant}); read_grant = mount(home, rw, 'read')
    refreshed = content(mcp(token, [('read', {'kind': 'spaces'})])[0])
    check(next(r for r in refreshed['spaces'] if r['id'] == rw)['name'] == 'Renamed shared' and
          not next(r for r in refreshed['spaces'] if r['id'] == rw)['can_write'], 'fresh catalog reflects rename and permission demotion')
    rpc('connection.delete', {'connection_id': read_grant})
    reduced = content(mcp(token, [('read', {'kind': 'spaces'})])[0])
    check(rw not in {r['id'] for r in reduced['spaces']} and reduced['total_count'] == 4, 'fresh catalog reflects grant removal')
    rpc('profile.revoke', {'profile_id': profile['id']})
    denial(mcp(token, [('read', {'kind': 'spaces'})])[0], 'unauthorized')
    denial(mcp('unknown-profile', [('read', {'kind': 'spaces'})])[0], 'unauthorized')
    receipt = {'status': 'PASS', 'boundary': 'packaged stdio MCP -> authenticated Unix socket -> SQLite',
               'executable': str(executable), 'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
               'state': str(state), 'checks': sorted(set(passed)), 'service_pid': service.pid,
               'only_synthetic_data': True}
finally:
    service.terminate()
    try:
        service.wait(timeout=5)
    except subprocess.TimeoutExpired:
        service.kill(); service.wait(timeout=5)
    log.close()
args.receipt.parent.mkdir(parents=True, exist_ok=True)
args.receipt.write_text(json.dumps(receipt, indent=2)+'\n')
print(json.dumps(receipt, indent=2))
