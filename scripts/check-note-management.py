#!/usr/bin/env python3
"""Verify note management through a real owner, stdio MCP, persistence and archive.

Every run creates a new isolated synthetic store. No personal Mio paths are used.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--executable',type=Path,required=True)
parser.add_argument('--receipt',type=Path,required=True)
args=parser.parse_args()
executable=args.executable.resolve(strict=True)
state=Path(tempfile.mkdtemp(prefix='mio-manage-',dir='/tmp'))
env=dict(os.environ,MIO_DATA_DIRECTORY=str(state));env.pop('MIO_PROFILE_TOKEN',None)
passed=[]
def check(condition,name):
    if not condition: raise AssertionError(name)
    passed.append(name)
def rpc(method,params=None,success=True):
    process=subprocess.run([str(executable),'--rpc',method,json.dumps(params or {})],env=env,capture_output=True,text=True,timeout=25)
    if not success:
        check(process.returncode!=0,'Rejected owner operation: '+method);return
    if process.returncode: raise RuntimeError(process.stderr)
    return json.loads(process.stdout)
def mcp(token,name,params,success=True):
    requests=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18','clientInfo':{'name':'Mio management acceptance','version':'1'}}},
              {'jsonrpc':'2.0','id':2,'method':'tools/list'},
              {'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':name,'arguments':params}}]
    result=subprocess.run([str(executable),'--mcp'],env=dict(env,MIO_PROFILE_TOKEN=token),input=''.join(json.dumps(r)+'\n' for r in requests),text=True,capture_output=True,timeout=30,check=True)
    replies=[json.loads(x) for x in result.stdout.splitlines()]
    check([t['name'] for t in replies[1]['result']['tools']]==['search','read','capture','revise','link'],'Five MCP tools retained')
    reply=replies[-1]['result']
    check(bool(reply.get('isError'))!=success,'MCP '+name+(' succeeds' if success else ' denies access'))
    return reply['structuredContent']
def pdf():
    text=b'BT /F1 14 Tf 30 180 Td (Synthetic source document) Tj ET'
    objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Count 1 /Kids [3 0 R] >>',
             b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 220] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
             b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',b'<< /Length '+str(len(text)).encode()+b' >>\nstream\n'+text+b'\nendstream']
    data=b'%PDF-1.4\n';offsets=[0]
    for i,obj in enumerate(objects,1): offsets.append(len(data));data+=f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n'
    start=len(data);data+=b'xref\n0 6\n0000000000 65535 f \n'
    data+=b''.join(f'{n:010} 00000 n \n'.encode() for n in offsets[1:])
    return data+f'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()
log=(state/'service.log').open('w')
def start():
    # SIGTERM may leave the previous synthetic socket inode. A fresh listener,
    # rather than inode existence, must gate the restarted owner.
    (state/'Runtime/bridge.sock').unlink(missing_ok=True)
    process=subprocess.Popen([str(executable),'--background'],env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=log)
    deadline=time.monotonic()+15
    while not (state/'Runtime/bridge.sock').exists():
        if process.poll() is not None or time.monotonic()>deadline: raise RuntimeError('Owner unavailable: '+str(state/'service.log'))
        time.sleep(.05)
    return process
def stop(process):
    process.terminate()
    try: process.wait(timeout=5)
    except subprocess.TimeoutExpired: process.kill();process.wait(timeout=5)
service=start()
try:
    parent=rpc('space.create',{'name':'Personal'})['id']
    child=rpc('space.create',{'name':'Genealogy','description':'Family evidence','color':'purple','parent_id':parent})['id']
    other=rpc('space.create',{'name':'Other'})['id']
    profiles={s:rpc('profile.create',{'space_id':s,'name':'Synthetic '+s})['token'] for s in (parent,child,other)}
    first=mcp(profiles[parent],'read',{'kind':'spaces'})
    check([x['id'] for x in first['spaces']]==[parent],'Nesting never grants descendant access')
    rpc('connection.create',{'from_space_id':parent,'to_space_id':child,'access':'read'})
    catalog=mcp(profiles[parent],'read',{'kind':'spaces'})
    entry=next(x for x in catalog['spaces'] if x['id']==child)
    check(entry['description']=='Family evidence' and entry['color']=='purple' and entry['parent_id']==parent,'MCP exposes edited metadata and parent')
    check([x['id'] for x in entry['path']]==[parent,child] and not entry['can_write'],'Authorized hierarchy preserves explicit read-only grant')
    hidden_parent=mcp(profiles[child],'read',{'kind':'spaces'})
    check(parent not in json.dumps(hidden_parent) and hidden_parent['spaces'][0]['parent_id'] is None,'Hidden parent metadata omitted')
    rpc('space.update',{'space_id':child,'name':'Family','description':'Updated evidence','color':'green'})
    check(next(x for x in mcp(profiles[parent],'read',{'kind':'spaces'})['spaces'] if x['id']==child)['name']=='Family','Metadata edit reaches a fresh MCP session')
    rpc('space.update',{'space_id':parent,'parent_id':child},success=False)
    target=rpc('note.create',{'space_id':child,'title':'Witness','body':'Original target'})
    note=rpc('note.create',{'space_id':child,'title':'Moving note','body':'managementneedle [[Witness]]'})
    source=pdf();file=rpc('note.create',{'space_id':child,'title':'Source PDF','file_name':'source.pdf','mime_type':'application/pdf','file_base64':base64.b64encode(source).decode(),'body':'Source annotation'})
    ids=[note['id'],file['id']]
    rpc('notes.bulk',{'action':'move','note_ids':ids+['missing'],'space_id':other},success=False)
    check(rpc('read',{'id':note['id']})['space_id']==child,'Failed batch leaves every note unchanged')
    moved=rpc('notes.bulk',{'action':'move','note_ids':ids,'space_id':other})
    check(moved['changed_count']==2,'Bulk move commits the full selection')
    current=mcp(profiles[other],'read',{'kind':'note','id':note['id']})
    check(current['revision_id']==note['revision_id'] and current['space_id']==other,'Move preserves identity and content revision')
    mcp(profiles[child],'read',{'kind':'note','id':note['id']},success=False)
    hits=mcp(profiles[other],'search',{'query':'managementneedle','scope':'notes'})['results']
    check(any(x['id']==note['id'] for x in hits),'Destination MCP search finds moved note')
    old=mcp(profiles[child],'search',{'query':'managementneedle','scope':'notes'})['results']
    check(not old,'Origin MCP search loses moved note')
    mcp(profiles[other],'revise',{'note_id':note['id'],'expected_revision':note['revision_id'],'title':'Moved note','body':'managementneedle [[Witness]] updated','idempotency_key':'management-revise'})
    rpc('connection.create',{'from_space_id':other,'to_space_id':child,'access':'read'})
    check(mcp(profiles[other],'read',{'kind':'note','id':note['id']})['links'][0]['note']['id']==target['id'],'Stable wikilink survives move and subsequent edit')
    file_read=mcp(profiles[other],'read',{'kind':'source','id':file['file_id']})
    check(file_read['sha256']==hashlib.sha256(source).hexdigest() and file_read['space_id']==other,'Owned file retains exact bytes and effective space through MCP')
    rpc('notes.bulk',{'action':'status','note_ids':ids,'status':'confirmed'})
    check(rpc('read',{'id':note['id']})['status']=='confirmed','Bulk status persists without changing body')
    current_revision=rpc('read',{'id':note['id']})['revision_id']
    rpc('notes.bulk',{'action':'delete','note_ids':ids})
    mcp(profiles[other],'read',{'kind':'note','id':note['id']},success=False)
    rpc('note.restore',{'note_id':note['id'],'revision_id':current_revision})
    check(rpc('read',{'id':note['id']})['space_id']==other,'Restore keeps destination location')
    rpc('note.restore',{'note_id':file['id'],'revision_id':file['revision_id']})
    archive=state/'management.mio';rpc('archive.export',{'path':str(archive)})
    check(rpc('archive.import',{'path':str(archive),'mode':'merge'})['imported_records']==0,'Archive merge is idempotent')
    stop(service);service=start()
    check(rpc('read',{'id':note['id']})['space_id']==other,'Location persists across owner restart')
    check(mcp(profiles[other],'read',{'kind':'source','id':file['file_id']})['sha256']==hashlib.sha256(source).hexdigest(),'File access persists across restart')
    receipt={'status':'PASS','boundary':'real owner process -> authenticated Unix IPC -> stdio MCP -> SQLite -> restart/archive','executable':str(executable),'executable_sha256':hashlib.sha256(executable.read_bytes()).hexdigest(),'state':str(state),'only_synthetic_data':True,'checks':sorted(set(passed))}
finally:
    stop(service);log.close()
args.receipt.parent.mkdir(parents=True,exist_ok=True);args.receipt.write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps(receipt,indent=2))
