"""Local-only administration: docker compose exec api python -m server.manage ..."""
import argparse
import json
import secrets
import sqlite3
import time
from pathlib import Path
from server.app import DB_PATH, db, digest, initialize

parser = argparse.ArgumentParser()
sub = parser.add_subparsers(dest='command', required=True)
sub.add_parser('invite')
sub.add_parser('devices')
owner = sub.add_parser('device-owner')
owner.add_argument('device_id')
owner.add_argument('name', choices=['Alex', 'Laura'])
sub.add_parser('install-link')
sub.add_parser('release-info')
release = sub.add_parser('publish-release')
release.add_argument('build', type=int)
revoke = sub.add_parser('revoke')
revoke.add_argument('device_id')
backup = sub.add_parser('backup')
backup.add_argument('destination')
args = parser.parse_args()
initialize()
if args.command == 'invite':
    code = secrets.token_urlsafe(24)
    with db() as c:
        c.execute('DELETE FROM invites WHERE expires<?', (time.time(),))
        c.execute('INSERT INTO invites VALUES(?,?)', (digest(code), time.time() + 600))
    print(code)
    print('One use; expires in 10 minutes.')
elif args.command == 'devices':
    with db() as c:
        print(json.dumps([dict(r) for r in c.execute('SELECT id,name,revoked,owner_name FROM devices')], indent=2))
elif args.command == 'device-owner':
    with db() as c:
        result = c.execute('UPDATE devices SET owner_name=? WHERE id=?', (args.name, args.device_id))
        if result.rowcount != 1:
            raise SystemExit('Device not found')
    print('Device owner saved.')
elif args.command == 'revoke':
    with db() as c:
        c.execute('UPDATE devices SET revoked=1,apns_token=NULL WHERE id=?', (args.device_id,))
elif args.command == 'backup':
    Path(args.destination).parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(DB_PATH) as source, sqlite3.connect(args.destination) as target:
        source.backup(target)
    Path(args.destination).chmod(0o600)
    print('Backup complete.')

elif args.command == 'install-link':
    from server.releases import issue_ticket
    print(issue_ticket()['url'])
elif args.command == 'release-info':
    from server.releases import latest
    release = latest()
    print(release.model_dump_json() if release else 'null')
elif args.command == 'publish-release':
    from server.releases import publish
    publish(args.build)
    print('Release published; update notifications queued.')
