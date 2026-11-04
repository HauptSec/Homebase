#!/usr/bin/env python3
"""Validate an exported ad hoc IPA and create server metadata. No signing secrets are copied."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path


def prepare(ipa, destination, commit, notes):
    ipa, destination = Path(ipa), Path(destination)
    with tempfile.TemporaryDirectory(prefix='homebase-verify-') as temp:
        root = Path(temp).resolve()
        with zipfile.ZipFile(ipa) as archive:
            for entry in archive.infolist():
                target = (root / entry.filename).resolve()
                if not target.is_relative_to(root):
                    raise ValueError('Unexpected archive path')
            archive.extractall(root)
        apps = list((root / 'Payload').glob('*.app'))
        if len(apps) != 1:
            raise ValueError('Expected exactly one application')
        app = apps[0]
        # zipfile extraction does not preserve executable permissions; restore those
        # from the ZIP before checking the signed bundle.
        with zipfile.ZipFile(ipa) as archive:
            for entry in archive.infolist():
                if entry.external_attr >> 16:
                    (root / entry.filename).chmod((entry.external_attr >> 16) & 0o777)
        subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
        info = plistlib.loads((app/'Info.plist').read_bytes())
        profile = plistlib.loads(subprocess.check_output(['/usr/bin/security','cms','-D','-i',str(app/'embedded.mobileprovision')]))
        entitlements = profile['Entitlements']
        if info['CFBundleIdentifier'] != 'xyz.hauptsec.homebase':
            raise ValueError('Unexpected bundle identifier')
        if not profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices') or entitlements.get('get-task-allow'):
            raise ValueError('Expected a registered-device distribution profile, not development/enterprise')
        if entitlements.get('aps-environment') != 'production':
            raise ValueError('Release must use production APNs')
        if entitlements.get('application-identifier') != 'BH744E96JG.xyz.hauptsec.homebase':
            raise ValueError('Signing identity changed; existing installations must keep their app identity')
        certificate_prefix = str(root/'signing-cert-')
        subprocess.run(['/usr/bin/codesign','-d','--extract-certificates='+certificate_prefix,str(app)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        certificate_end = subprocess.check_output(['/usr/bin/openssl','x509','-inform','DER','-in',certificate_prefix+'0','-noout','-enddate'],text=True).strip().split('=',1)[1]
        certificate_expiry = datetime.strptime(certificate_end,'%b %d %H:%M:%S %Y %Z').replace(tzinfo=timezone.utc).timestamp()
        expires = min(profile['ExpirationDate'].replace(tzinfo=timezone.utc).timestamp(), certificate_expiry)
        if expires < datetime.now(timezone.utc).timestamp()+86400:
            raise ValueError('Provisioning expires in less than one day')
        build = int(info['CFBundleVersion'])
        if not 2 <= build <= 9999:
            raise ValueError('Use increasing integer builds from 2 through 9999')
        with ipa.open('rb') as stream:
            checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
        metadata = dict(build=build,version=info['CFBundleShortVersionString'],bundleId=info['CFBundleIdentifier'],sha256=checksum,size=ipa.stat().st_size,expiresAt=expires,notes=notes,sourceCommit=commit,deviceCount=len(profile['ProvisionedDevices']))
        destination.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(ipa,destination/'Homebase.ipa')
        (destination/'release.json').write_text(json.dumps(metadata,indent=2)+'\n')
        for file in destination.iterdir(): file.chmod(0o644)
        destination.chmod(0o755)
        print(f'Validated ad hoc build {build}; {metadata["deviceCount"]} registered device(s); signing expires {datetime.fromtimestamp(expires, timezone.utc).date()}')
        return metadata

if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('ipa');parser.add_argument('destination');parser.add_argument('--commit',required=True);parser.add_argument('--notes',required=True)
    args=parser.parse_args()
    prepare(args.ipa,args.destination,args.commit,args.notes)
