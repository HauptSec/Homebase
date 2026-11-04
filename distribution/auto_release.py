#!/usr/bin/env python3
"""Logged-in Mac release agent. Only successful Verify commits on main are executed.

The launch agent points to a private, dedicated checkout, never the working copy.
No GitHub Actions self-hosted runner, public IPA asset, or uploaded signing key.
"""
import argparse
import fcntl
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO='HauptSec/Homebase'
STATE=Path(os.environ.get('HOMEBASE_RELEASE_STATE',str(Path.home()/'Library/Application Support/HomebaseRelease')))
CHECKOUT=STATE/'checkout'
HOST=os.environ.get('HOMEBASE_RELEASE_HOST','alex@10.10.1.120')
REMOTE='/home/alex/homebase'
GH=shutil.which('gh') or '/opt/homebrew/bin/gh'


def run(args, **kwargs):
    print('+ '+shlex.join([str(x) for x in args]),flush=True)
    return subprocess.run(args,check=True,**kwargs)


def output(args, **kwargs):
    return subprocess.check_output(args,text=True,**kwargs).strip()


def remote(command):
    return output(['/usr/bin/ssh','-o','BatchMode=yes','-o','ConnectTimeout=10',HOST,command])


def publish(folder, build):
    # A staging directory is renamed only after both files arrived. Existing immutable
    # builds are accepted only if their metadata is identical (safe retry).
    stage=REMOTE+f'/releases/.incoming-{build}'
    remote('mkdir -p '+shlex.quote(stage)+' && chmod 755 '+shlex.quote(stage))
    run(['/usr/bin/scp','-q',str(folder/'Homebase.ipa'),str(folder/'release.json'),HOST+':'+stage+'/'])
    code='''import json,os,pathlib,sys
root=pathlib.Path(sys.argv[1]); build=sys.argv[2]; stage=root/('.incoming-'+build); final=root/build
for p in stage.iterdir(): p.chmod(0o644)
if final.exists():
 assert json.loads((stage/'release.json').read_text()) == json.loads((final/'release.json').read_text()), 'Build collision'
else: stage.rename(final)
'''
    remote('python3 -c '+shlex.quote(code)+' '+shlex.quote(REMOTE+'/releases')+' '+str(build))
    print(remote('cd '+shlex.quote(REMOTE)+' && docker compose exec -T api python -m server.manage publish-release '+str(build)),flush=True)


def main(force=False):
    STATE.mkdir(parents=True,exist_ok=True);STATE.chmod(0o700)
    with (STATE/'agent.lock').open('w') as lock:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: return
        if not CHECKOUT.exists():
            raise RuntimeError('Install the release agent into a dedicated checkout first')
        run(['git','fetch','--quiet','origin','main'],cwd=CHECKOUT)
        commit=output(['git','rev-parse','origin/main'],cwd=CHECKOUT)
        runs=json.loads(output([GH,'api',f'repos/{REPO}/actions/workflows/ci.yml/runs?head_sha={commit}&event=push&per_page=1']))['workflow_runs']
        if not runs or runs[0]['head_sha'] != commit or runs[0]['conclusion'] != 'success':
            print('Waiting for verified main.',flush=True);return
        # Only this deploy-only clone is reset. The user's working directory is untouched.
        run(['git','reset','--hard',commit],cwd=CHECKOUT)
        source=output(['git','log','-1','--format=%H','--','ios','distribution'],cwd=CHECKOUT)
        statefile=STATE/'published.json'
        state=json.loads(statefile.read_text()) if statefile.exists() else {}
        if not force and state.get('source')==source and state.get('expiresAt',0)>time.time()+30*86400:
            print('No iOS release needed.',flush=True);return
        live=json.loads(remote('cd '+shlex.quote(REMOTE)+' && docker compose exec -T api python -m server.manage release-info'))
        # Do not publish against a server still running older/unverified route code.
        deployed=remote('cat '+shlex.quote(REMOTE+'/.git/homebase-deployed'))
        if deployed != commit:
            print('Waiting for server deployment of the same verified commit.',flush=True);return
        build=max(live['build'] if live else 1,state.get('build',1))+1
        if build>9999: raise RuntimeError('Build numbering needs maintenance before publishing')
        job=STATE/'work'/str(build)
        job.mkdir(parents=True,exist_ok=True)
        archive=job/'Homebase.xcarchive'; export=job/'export'
        with (STATE/'last-build.log').open('w') as log:
            run(['/usr/bin/xcodebuild','-project','ios/Homebase.xcodeproj','-scheme','Homebase','-configuration','Release','-destination','generic/platform=iOS','-archivePath',str(archive),'-derivedDataPath',str(STATE/'DerivedData'),'-allowProvisioningUpdates',f'CURRENT_PROJECT_VERSION={build}','archive'],cwd=CHECKOUT,stdout=log,stderr=subprocess.STDOUT)
            run(['/usr/bin/xcodebuild','-exportArchive','-archivePath',str(archive),'-exportPath',str(export),'-exportOptionsPlist','distribution/ExportOptions.plist','-allowProvisioningUpdates'],cwd=CHECKOUT,stdout=log,stderr=subprocess.STDOUT)
        ipas=list(export.glob('*.ipa'))
        if len(ipas)!=1: raise RuntimeError('Expected one exported IPA')
        # Import the validator from this verified checkout, including agent upgrades.
        import importlib.util
        spec=importlib.util.spec_from_file_location('package_release',CHECKOUT/'distribution/package_release.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        notes=output(['git','log','-1','--format=%s','--','ios','distribution'],cwd=CHECKOUT)
        folder=job/'publish'
        metadata=module.prepare(ipas[0],folder,commit,notes)
        if metadata['expiresAt']<time.time()+30*86400:
            raise RuntimeError('Renew the ad hoc profile/certificate in Xcode before the next release; existing profile has under 30 days remaining')
        publish(folder,build)
        temp=STATE/'published.tmp'
        temp.write_text(json.dumps(dict(source=source,build=build,expiresAt=metadata['expiresAt'],commit=commit)))
        temp.chmod(0o600);temp.replace(statefile)
        # Keep the last two local build jobs. Server packages remain immutable.
        jobs=sorted((STATE/'work').iterdir(),key=lambda p:int(p.name))
        for old in jobs[:-2]: shutil.rmtree(old)
        (STATE/'last-error.txt').unlink(missing_ok=True)
        print(f'Published Homebase build {build}.',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--force',action='store_true');args=parser.parse_args()
    try: main(args.force)
    except Exception as error:
        STATE.mkdir(parents=True,exist_ok=True)
        (STATE/'last-error.txt').write_text(f'{time.ctime()}: {type(error).__name__}: {error}\n')
        raise
