import hashlib
import json
import tempfile
import time
import unittest
from pathlib import Path
from fastapi.testclient import TestClient
from server import app, releases

class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        app.DB_PATH = self.temp.name + '/db.sqlite'
        releases.RELEASES = Path(self.temp.name) / 'releases'
        app.initialize()
        with app.db() as c:
            c.execute('INSERT INTO devices(id,name,token_hash) VALUES(?,?,?)', ('phone','Phone',app.digest('device-secret')))
        self.headers = {'Authorization':'Bearer device-secret'}
        self.client = TestClient(app.app)
        self.make_release(2)

    def tearDown(self):
        self.temp.cleanup()

    def make_release(self, build):
        folder = releases.RELEASES / str(build)
        folder.mkdir(parents=True)
        data = b'test package ' + str(build).encode()
        (folder/'Homebase.ipa').write_bytes(data)
        metadata = dict(build=build, version='1.0', bundleId='xyz.hauptsec.homebase', sha256=hashlib.sha256(data).hexdigest(), size=len(data), expiresAt=time.time()+86400*90, notes='<script>alert(1)</script>', sourceCommit='a'*40, deviceCount=1)
        (folder/'release.json').write_text(json.dumps(metadata))
        releases.publish(build)
        return metadata

    def ticket(self):
        result=self.client.post('/v1/releases/link',headers=self.headers,json={})
        self.assertEqual(result.status_code,200)
        return result.json()['url'].split('ticket=')[1]

    def test_download_requires_scoped_ticket(self):
        self.assertEqual(self.client.get('/v1/releases/latest').status_code,401)
        self.assertEqual(self.client.get('/install/package.ipa').status_code,403)
        self.assertEqual(self.client.get('/install/package.ipa?ticket=device-secret').status_code,403)
        ticket=self.ticket()
        page=self.client.get('/install',params={'ticket':ticket})
        self.assertNotIn('<script>',page.text)
        self.assertIn('&lt;script&gt;',page.text)
        self.assertEqual(page.headers['referrer-policy'],'no-referrer')
        self.assertEqual(page.headers['cache-control'],'no-store')
        package=self.client.get('/install/package.ipa',params={'ticket':ticket})
        self.assertEqual(package.content,b'test package 2')
        self.assertEqual(self.client.get('/v1/sync',headers={'Authorization':'Bearer '+ticket}).status_code,401)

    def test_manifest_and_ticket_stay_on_same_build(self):
        import plistlib
        ticket=self.ticket()
        self.make_release(3)
        response=self.client.get('/install/manifest.plist',params={'ticket':ticket})
        data=plistlib.loads(response.content)
        self.assertEqual(data['items'][0]['metadata']['bundle-version'],'2')
        self.assertIn('ticket='+ticket,data['items'][0]['assets'][0]['url'])

    def test_expired_ticket_and_revocation(self):
        ticket=self.ticket()
        with app.db() as c:
            c.execute('UPDATE install_tickets SET expires=0')
        self.assertEqual(self.client.get('/install/package.ipa',params={'ticket':ticket}).status_code,403)
        ticket=self.ticket()
        with app.db() as c:
            c.execute('UPDATE devices SET revoked=1')
        self.assertEqual(self.client.get('/install/package.ipa',params={'ticket':ticket}).status_code,403)

    def test_immutable_build_and_integrity(self):
        releases.publish(2)
        (releases.RELEASES/'2'/'Homebase.ipa').write_bytes(b'corrupt')
        with self.assertRaises(ValueError): releases.publish(2)

    def test_old_links_reject_expired_signing(self):
        ticket=self.ticket()
        with app.db() as c:
            meta=json.loads(c.execute('SELECT metadata FROM app_releases WHERE build=2').fetchone()[0])
            meta['expiresAt']=time.time()-1
            c.execute('UPDATE app_releases SET metadata=?',(json.dumps(meta),))
        self.assertEqual(self.client.get('/install/manifest.plist',params={'ticket':ticket}).status_code,410)
        self.assertIsNone(self.client.get('/v1/releases/latest',headers=self.headers).json()['release'])
