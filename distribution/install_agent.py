#!/usr/bin/env python3
"""Install the user's local macOS release poller. Run after pushing and verifying main."""
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

state=Path.home()/'Library/Application Support/HomebaseRelease'
checkout=state/'checkout'
state.mkdir(parents=True,exist_ok=True);state.chmod(0o700)
if not checkout.exists():
    subprocess.run(['git','clone','https://github.com/HauptSec/Homebase.git',str(checkout)],check=True)
label='xyz.hauptsec.homebase.release'
plist=Path.home()/'Library/LaunchAgents'/f'{label}.plist'
plist.parent.mkdir(parents=True,exist_ok=True)
config={
 'Label':label,
 'ProgramArguments':[sys.executable,str(checkout/'distribution/auto_release.py')],
 'WorkingDirectory':str(checkout),
 'StartInterval':300,
 'RunAtLoad':True,
 'ProcessType':'Background',
 'EnvironmentVariables':{'PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin','HOMEBASE_RELEASE_STATE':str(state)},
 'StandardOutPath':str(state/'agent.log'),
 'StandardErrorPath':str(state/'agent-error.log'),
}
plist.write_bytes(plistlib.dumps(config));plist.chmod(0o600)
domain=f'gui/{os.getuid()}'
subprocess.run(['launchctl','bootout',domain,str(plist)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
subprocess.run(['launchctl','bootstrap',domain,str(plist)],check=True)
print(f'Installed {label}; checks every five minutes while this Mac is logged in.')
print(f'Logs: {state}')
