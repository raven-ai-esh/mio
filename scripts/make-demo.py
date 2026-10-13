#!/usr/bin/env python3
"""Create fictional showcase memory in a new empty directory. Never uses your vault."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--executable', type=Path, required=True)
parser.add_argument('--data-directory', type=Path, required=True)
parser.add_argument('--receipt', type=Path, required=True)
args = parser.parse_args()
state = args.data_directory.resolve()
state.mkdir(parents=True, exist_ok=True)
if list(state.iterdir()):
    raise SystemExit('Demo requires a new empty directory; existing memory is preserved.')
executable = args.executable.resolve(strict=True)
env = dict(os.environ, MIO_DATA_DIRECTORY=str(state))
env.pop('MIO_PROFILE_TOKEN', None)
# Match BridgeRuntime's Darwin socket-path fallback for long data directories.
# The directory must exist before Foundation standardizes its /private/var alias.
(state/'Runtime').mkdir(mode=0o700)
socket_path = state/'Runtime/bridge.sock'
if len(os.fsencode(socket_path)) >= 104:
    # Foundation canonicalizes /private/var aliases differently from pathlib.
    runtime_directory = subprocess.check_output(['swift', '-e',
        'import Foundation; print(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL.path)',
        str(state/'Runtime')], text=True).strip()
    digest = hashlib.sha256(os.fsencode(runtime_directory)).hexdigest()[:24]
    socket_path = Path(tempfile.gettempdir())/f'mio-{os.getuid()}-{digest}'/'bridge.sock'
service_log = (state/'service.log').open('w')
service = subprocess.Popen([str(executable), '--background'], env=env, stdin=subprocess.DEVNULL,
                           stdout=service_log, stderr=service_log)
def rpc(method, params=None):
    return json.loads(subprocess.check_output([str(executable), '--rpc', method, json.dumps(params or {})], env=env, text=True, timeout=30))

def brief_pdf():
    pages = [
        ['AURORA / DESIGN BRIEF', 'Make memory visible.', 'Keep the interface quiet and the evidence close.',
         'Every important decision should point to its source.', 'Connections reveal context; they do not expand access.'],
        ['AURORA / RECALL PRINCIPLES', 'Find the idea. Follow the evidence.', 'Search combines exact terms and semantic similarity.',
         'Open the original page before trusting a summary.', 'Replay the recorded memory operations, one step at a time.']]
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [4 0 R 6 0 R] /Count 2 >>',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    for index, lines in enumerate(pages):
        stream = b'BT /F1 22 Tf 54 720 Td (' + lines[0].encode() + b') Tj /F1 13 Tf 0 -64 Td '
        stream += b' '.join(b'('+line.encode()+b') Tj 0 -32 Td' for line in lines[1:]) + b' ET'
        content_id = 5+index*2
        objects += [f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {content_id} 0 R >>'.encode(),
                    b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'\nendstream']
    data = b'%PDF-1.4\n';offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data));data += f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n'
    xref = len(data);data += f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode()
    data += b''.join(f'{o:010} 00000 n \n'.encode() for o in offsets[1:])
    data += f'trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    return data

try:
    deadline = time.monotonic()+10
    while not socket_path.exists():
        if service.poll() is not None or time.monotonic()>deadline:
            raise RuntimeError(f'Demo owner did not start (exit={service.poll()}); see {state}/service.log. Expected socket: {socket_path}')
        time.sleep(.05)
    groups = {
        'Aurora': ('blue', ['Memory, with a paper trail','Design for clarity','Keep proof attached','Scope before you search','A quiet workspace','Notes that connect','A readable graph','Make context visible','Build small, useful tools','A place for decisions','Capture the useful part','Trust the source']),
        'Research': ('purple', ['Recall with citations','Context beats summaries','Sources make memory auditable','Search beyond keywords','Exact source revisions','Follow the evidence','Hybrid retrieval','The original page matters','Human review','Reliable recall','Keep uncertainty visible','Multimodal memory']),
        'Personal': ('green', ['Morning notes','Ideas worth keeping','A learning journal','Small experiments','Weekly reflections','A reading list','Thoughts in progress','A useful habit']),
        'Agent Inbox': ('orange', ['New observations','Decisions to verify','Reusable context','Next research steps','Patterns noticed','Open questions','Evidence collected','What changed'])}
    spaces = {name:rpc('space.create',{'name':name,'color':color})['id'] for name,(color,_) in groups.items()}
    notes = {}
    for group,(_,titles) in groups.items():
        for index,title in enumerate(titles):
            next_title = titles[(index+1)%len(titles)]
            body = f'# {title}\n\nA small piece of the Aurora workspace: knowledge that stays useful because its context is easy to inspect.\n\n## What to remember\n\n- Keep the original evidence close.\n- Separate facts, hypotheses and open questions.\n- Make the next useful connection explicit.\n\n## Related\n\n[[{next_title}]]\n\nThis is fictional demonstration content, created for Mio.'
            notes[title] = rpc('note.create',{'space_id':spaces[group],'title':title,'body':body,'status':'confirmed' if index%3==0 else 'hypothesis'})
    for group,(_,titles) in groups.items():
        for index,title in enumerate(titles):
            rpc('link.create',{'from_note_id':notes[title]['id'],'to_note_id':notes[titles[(index+3)%len(titles)]]['id'],'kind':'related'})
    for left,right in [('Memory, with a paper trail','Sources make memory auditable'),('Design for clarity','Context beats summaries'),('Keep proof attached','Exact source revisions'),('Scope before you search','Reusable context')]:
        rpc('link.create',{'from_note_id':notes[left]['id'],'to_note_id':notes[right]['id'],'kind':'supports'})
    brief = rpc('note.create',{'space_id':spaces['Research'],'title':'Aurora design brief','body':'The original design brief for the Aurora workspace. Two pages of source evidence. [[Follow the evidence]]',
        'file_name':'Aurora Design Brief.pdf','mime_type':'application/pdf','file_base64':base64.b64encode(brief_pdf()).decode(),'status':'confirmed'})
    notes['Aurora design brief'] = brief
    anchor = notes['Memory, with a paper trail']
    body = '# Memory, with a paper trail\n\nGood memory does more than keep an answer. It keeps the context that makes the answer trustworthy.\n\n## A simple rule\n\n**Find the idea. Follow the evidence.**\n\nEvery useful note can carry its sources, exact versions and connections. A person can inspect the same memory an agent uses.\n\n## Explore next\n\n[[Design for clarity]] · [[Keep proof attached]] · [[Scope before you search]]\n\nThe Aurora workspace is fictional demonstration content.'
    notes['Memory, with a paper trail'] = rpc('note.update',{'note_id':anchor['id'],'expected_revision':anchor['revision_id'],'title':'Memory, with a paper trail','body':body,'source_ids':[brief['id']]})
    rpc('connection.create',{'from_space_id':spaces['Aurora'],'to_space_id':spaces['Research'],'access':'read'})
    rpc('connection.create',{'from_space_id':spaces['Aurora'],'to_space_id':spaces['Agent Inbox'],'access':'write'})
    profile = rpc('profile.create',{'space_id':spaces['Aurora'],'name':'Studio agent'})
    operations = [('read',{'kind':'spaces'}),('search',{'query':'Sources make memory auditable','scope':'notes','space_ids':[spaces['Research']]}),
                  ('read',{'kind':'note','id':notes['Memory, with a paper trail']['id']}),('read',{'kind':'note','id':notes['Keep proof attached']['id']}),
                  ('read',{'kind':'note','id':notes['Sources make memory auditable']['id']}),('read',{'kind':'source','id':brief['file_id'],'offset':0})]
    requests = [{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18','clientInfo':{'name':'Mio showcase','version':'1'}}}]
    requests += [{'jsonrpc':'2.0','id':i+2,'method':'tools/call','params':{'name':name,'arguments':params}} for i,(name,params) in enumerate(operations)]
    run = subprocess.run([str(executable),'--mcp'],env=dict(env,MIO_PROFILE_TOKEN=profile['token']),input=''.join(json.dumps(q)+'\n' for q in requests),text=True,capture_output=True,timeout=60,check=True)
    replies = [json.loads(line) for line in run.stdout.splitlines()]
    if any(r.get('result',{}).get('isError') for r in replies):raise RuntimeError('Demo MCP operation failed')
    session = replies[1]['result']['structuredContent']['interaction_session_id']
    args.receipt.parent.mkdir(parents=True,exist_ok=True)
    args.receipt.write_text(json.dumps({'state':str(state),'spaces':spaces,'notes':{name:note['id'] for name,note in notes.items()},'session_id':session,'brief_note_id':brief['id'],'only_fictional_data':True},indent=2)+'\n')
    print(json.dumps({'state':str(state),'notes':len(notes),'spaces':len(spaces),'session_id':session,'only_fictional_data':True}))
finally:
    service.terminate()
    try:service.wait(timeout=5)
    except subprocess.TimeoutExpired:service.kill();service.wait(timeout=5)
    service_log.close()
