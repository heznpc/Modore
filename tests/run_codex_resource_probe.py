#!/usr/bin/env python3
"""Offline integration probe through the installed Codex tool executor.

No AI service, credentials, real device command, or persisted hook trust is used.
The local Responses fixture emits fixed calls to a fake xcrun; hooks execute the
production policy against a fixture inventory. Keep the output directory as proof.
"""
import argparse
import http.server
import importlib.util
import json
import os
import shlex
from pathlib import Path
import subprocess
import threading

REPO = Path(__file__).resolve().parents[1]
CODEX = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex'


def run(out, app_request=None):
    out.mkdir(parents=True, exist_ok=False)
    if app_request: (out/'app-request.json').write_bytes(app_request.read_bytes())
    allowed_id = json.loads(app_request.read_text())['id'] if app_request else 'allowed'
    home = out/'.codex'
    work = out/'project'; work.mkdir(exist_ok=True)
    state = out/'state'; state.mkdir(exist_ok=True)
    fake = out/'xcrun'
    fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> '+shlex.quote(str(out/'executed'))+'\n')
    fake.chmod(0o700)
    delivery = work/'delivery.py'
    delivery.write_text(f"import subprocess\nsubprocess.run([{str(fake)!r},'devicectl','device','install','app'])\n")
    mcp = out/'mcp.py'
    mcp.write_text('''import sys,json,pathlib
for line in sys.stdin:
 p=json.loads(line); method=p.get('method')
 if 'id' not in p: continue
 if method=='initialize': result={'protocolVersion':'2024-11-05','capabilities':{'tools':{}},'serverInfo':{'name':'device_fixture','version':'1'}}
 elif method=='tools/list': result={'tools':[{'name':name,'description':'Offline fake device operation','inputSchema':{'type':'object','properties':{'simulatorId':{'type':'string'},'deviceId':{'type':'string'}}}} for name in ('install_app_device','launch_app_sim')]}
 elif method=='tools/call':
  with pathlib.Path(%r).open('a') as f: f.write(json.dumps(p['params'])+'\\n')
  result={'content':[{'type':'text','text':'fixture ran'}]}
 else: result={}
 print(json.dumps({'jsonrpc':'2.0','id':p['id'],'result':result}),flush=True)
''' % str(out/'mcp-executed.jsonl'))
    inventory = {'devices': {'fixture-ios': [
        {'udid': x, 'name': 'Fixture', 'state': 'Shutdown', 'isAvailable': True,
         'deviceTypeIdentifier': 'fixture-phone', 'dataPath': '/fixture/'+x} for x in (allowed_id,'wrong')]}}
    wrapper = out/'hook.py'
    wrapper.write_text('''import importlib.util,json,sys,pathlib
spec=importlib.util.spec_from_file_location('resources',%r)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
root=pathlib.Path(%r)
rows=m.simulator_rows(%r)
m.devices=lambda *a,**k: rows
m.volumes=lambda: ([],[])
p=json.load(sys.stdin)
if p['hook_event_name']=='UserPromptSubmit':
    # The exact bind request used by ResourceConnectionSheet; permanent setting.
    req={'action':'bind','id':rows[0]['id'],'fingerprint':rows[0]['fingerprint'],
         'provider':'codex','session':p['session_id'],'project':p['cwd']}
    saved=root.parent/'app-request.json'
    if saved.exists(): req.update(json.loads(saved.read_text()),project=p['cwd'],fingerprint=rows[0]['fingerprint'])
    m.dispatch(req,root)
    m.register({**req,'session':p['session_id'],'runtime':'fixture-ios'},root)
    result=m.turn_hook('codex',p,root)
else:
    result=m.resource_guard('codex',p,root) if p['hook_event_name']=='PreToolUse' else m.turn_hook('codex',p,root)
with (root.parent/'hook-events.jsonl').open('a') as f:
    f.write(json.dumps({'event':p['hook_event_name'],'tool':p.get('tool_name'),'result':result})+'\\n')
print(json.dumps(result))
''' % (str(REPO/'scripts/work_resources.py'), str(state), inventory))
    spec = importlib.util.spec_from_file_location('resources', REPO/'scripts/work_resources.py')
    policy = importlib.util.module_from_spec(spec); spec.loader.exec_module(policy)
    policy.install_hooks('codex', root=state, home=out)
    hooks = json.loads((home/'hooks.json').read_text())
    # Keep the installer's events/matchers. Substitute only the fixture inventory adapter.
    for groups in hooks['hooks'].values():
        for group in groups:
            for handler in group['hooks']:
                if ' resources ' in handler['command']:
                    handler['command']=f'/usr/bin/python3 {shlex.quote(str(wrapper))}'
    (home/'hooks.json').write_text(json.dumps(hooks))
    fake = shlex.quote(str(fake))
    sequence = [f'{fake} simctl launch {allowed_id} app.fixture', f'{fake} simctl launch wrong app.fixture',
                f'{fake} devicectl device install app --device FAKE fixture.app',
                f"bash -c '{fake} devicectl device process launch --device FAKE app.fixture'",
                'python3 delivery.py', 'MCP_PHYSICAL', 'MCP_WRONG_SIM', 'MCP_ALLOWED',
                f"{fake} xcodebuild test -destination 'platform=iOS Simulator,id=wrong'",
                f"echo '{fake} devicectl device install app' | sh"]
    requests = []
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            self.send_response(200);self.end_headers();self.wfile.write(b'{}')
        def do_POST(self):
            body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append(body)
            (out/'requests.json').write_text(json.dumps(requests))
            index=len(requests)-1
            if index < len(sequence):
                names=[t.get('name') for t in body.get('tools',[]) if t.get('type')=='function']
                name=next((n for n in ('exec_command','shell_command','shell') if n in names), 'exec_command')
                args={'cmd':sequence[index]} if name=='exec_command' else {'command':sequence[index]}
                if name=='shell':args={'command':['/bin/sh','-c',sequence[index]]}
                if sequence[index]=='MCP_PHYSICAL':
                    name='install_app_device';args={'deviceId':'FAKE'}
                if sequence[index] in ('MCP_WRONG_SIM','MCP_ALLOWED'):
                    name='launch_app_sim';args={'simulatorId':allowed_id if sequence[index]=='MCP_ALLOWED' else 'wrong'}
                item={'type':'function_call','id':f'fc{index}','call_id':f'call{index}','name':name,'arguments':json.dumps(args)}
                if sequence[index].startswith('MCP_'): item['namespace']='mcp__device_fixture'
            else:
                item={'type':'message','id':'final','role':'assistant','status':'completed',
                      'content':[{'type':'output_text','text':'Offline resource probe finished.','annotations':[]}]}
            response={'id':f'resp{index}','object':'response','status':'completed','output':[item],
                      'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
            events=[{'type':'response.created','response':{**response,'status':'in_progress','output':[]}},
                    {'type':'response.output_item.added','output_index':0,'item':item},
                    {'type':'response.output_item.done','output_index':0,'item':item},
                    {'type':'response.completed','response':response}]
            self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
            for event in events:self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode())
            self.wfile.flush()
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0), Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    config=f'''model = "gpt-5.4"
model_provider = "fixture"
approval_policy = "never"
[model_providers.fixture]
name = "Offline fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
[features]
hooks = true
shell_snapshot = false
[mcp_servers.device_fixture]
command = "/usr/bin/python3"
args = [{json.dumps(str(mcp))}]
'''
    (home/'config.toml').write_text(config)
    env={**os.environ,'CODEX_HOME':str(home)}
    # Trust bypass is confined to this vetted, temporary offline test fixture.
    args=[CODEX,'exec','--dangerously-bypass-hook-trust','--skip-git-repo-check','--ephemeral',
          '-C',str(work),'--sandbox','danger-full-access','--json','Run the fixed offline resource probe.']
    try:
        result=subprocess.run(args,env=env,capture_output=True,text=True,timeout=100)
        (out/'codex.jsonl').write_text(result.stdout)
        (out/'codex.stderr').write_text(result.stderr)
    finally: server.shutdown()
    executed=(out/'executed').read_text().splitlines() if (out/'executed').exists() else []
    events=[json.loads(l) for l in (out/'hook-events.jsonl').read_text().splitlines()] if (out/'hook-events.jsonl').exists() else []
    denied=sum(e['result'].get('hookSpecificOutput',{}).get('permissionDecision')=='deny' for e in events)
    report={'exitCode':result.returncode,'requests':len(requests),'executed':executed,'denied':denied,
            'promptContainsBinding':bool(requests and 'resourceID' in json.dumps(requests[0])),
            'swiftAppRequest':bool(app_request), 'realDevicesAccessed':False}
    mcp_calls=[json.loads(line) for line in (out/'mcp-executed.jsonl').read_text().splitlines()] if (out/'mcp-executed.jsonl').exists() else []
    report['mcpExecuted']=[{k: call[k] for k in ('name','arguments')} for call in mcp_calls]
    expected_mcp=[{'name':'launch_app_sim','arguments':{'simulatorId':allowed_id}}]
    report['passed']=result.returncode==0 and executed==[f'simctl launch {allowed_id} app.fixture'] and denied==8 and report['promptContainsBinding'] and report['mcpExecuted']==expected_mcp
    (out/'report.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report))
    return 0 if report['passed'] else 1


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('output',type=Path)
    parser.add_argument('--app-request',type=Path)
    args=parser.parse_args()
    raise SystemExit(run(args.output.resolve(), args.app_request))
