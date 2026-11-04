import os
import tempfile
import time
import unittest
from uuid import uuid4
from fastapi.testclient import TestClient
from server import app as module

class APITests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        module.DB_PATH = self.directory.name + '/test.sqlite'
        module.initialize()
        self.client = TestClient(module.app)
        self.a = self.pair('Alex')
        self.b = self.pair('Partner')

    def tearDown(self):
        self.directory.cleanup()

    def pair(self, name):
        code = str(uuid4())
        with module.db() as c:
            c.execute('INSERT INTO invites VALUES(?,?)', (module.digest(code), time.time()+60))
        response = self.client.post('/v1/pair', json={'code': code, 'name': name})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self.client.post('/v1/pair', json={'code': code, 'name': name}).status_code, 403)
        return {'Authorization': 'Bearer ' + response.json()['token']}

    def mutation(self, **fields):
        return {'mutationId': str(uuid4()), 'baseRevision': 0, 'item': {'id': str(uuid4()), 'kind': 'grocery', 'title': 'Milk', **fields}}

    def test_auth_and_revocation(self):
        self.assertEqual(self.client.get('/v1/sync').status_code, 401)
        with module.db() as c:
            c.execute('UPDATE devices SET revoked=1')
        self.assertEqual(self.client.get('/v1/sync', headers=self.a).status_code, 401)

    def test_retry_conflict_delete_and_sync(self):
        data = self.mutation()
        first = self.client.post('/v1/mutations', headers=self.a, json=data)
        self.assertEqual(first.status_code, 200)
        retry = self.client.post('/v1/mutations', headers=self.a, json=data)
        self.assertEqual(first.json(), retry.json())
        data['mutationId'] = str(uuid4())
        self.assertEqual(self.client.post('/v1/mutations', headers=self.b, json=data).status_code, 409)
        data['baseRevision'] = 1
        data['item']['deleted'] = True
        self.assertEqual(self.client.post('/v1/mutations', headers=self.b, json=data).status_code, 200)
        result = self.client.get('/v1/sync', headers=self.a).json()
        self.assertEqual(len(result['items']), 2)
        self.assertTrue(result['items'][-1]['deleted'])
        self.assertEqual(self.client.get('/v1/sync', params={'after': result['cursor']}, headers=self.a).json()['items'], [])

    def test_atomic_parallel_edit(self):
        from concurrent.futures import ThreadPoolExecutor
        data = self.mutation()
        def send(_):
            return self.client.post('/v1/mutations', headers=self.a, json={**data, 'mutationId': str(uuid4())}).status_code
        with ThreadPoolExecutor(max_workers=4) as pool:
            statuses = list(pool.map(send, range(4)))
        self.assertEqual(statuses.count(200), 1)
        self.assertEqual(statuses.count(409), 3)

    def test_validation(self):
        data = self.mutation(amountCents=-1)
        self.assertEqual(self.client.post('/v1/mutations', headers=self.a, json=data).status_code, 422)
        self.assertEqual(self.client.get('/v1/sync?after=-1', headers=self.a).status_code, 422)

    def test_push_only_to_other_device(self):
        self.client.post('/v1/push', headers=self.a, json={'token': 'a'*64})
        self.client.post('/v1/push', headers=self.b, json={'token': 'b'*64})
        self.client.post('/v1/mutations', headers=self.a, json=self.mutation())
        with module.db() as c:
            jobs = c.execute('SELECT * FROM notifications').fetchall()
        self.assertEqual(len(jobs), 1)
        self.assertNotIn('Milk', jobs[0]['body'])

    def test_calendar_bridge_exclusive_and_revocable(self):
        self.assertEqual(self.client.post('/v1/calendar/claim', headers=self.a, json={}).status_code, 200)
        self.assertEqual(self.client.post('/v1/calendar/claim', headers=self.b, json={}).status_code, 409)
        self.client.post('/v1/calendar/release', headers=self.b, json={})
        self.assertEqual(self.client.post('/v1/calendar/claim', headers=self.b, json={}).status_code, 409)
        self.client.post('/v1/calendar/release', headers=self.a, json={})
        self.assertEqual(self.client.post('/v1/calendar/claim', headers=self.b, json={}).status_code, 200)

    def test_expired_invite(self):
        code = str(uuid4())
        with module.db() as c:
            c.execute('INSERT INTO invites VALUES(?,?)', (module.digest(code), time.time()-1))
        self.assertEqual(self.client.post('/v1/pair', json={'code': code, 'name': 'Expired'}).status_code, 403)

    def test_backup_is_consistent(self):
        import sqlite3
        self.client.post('/v1/mutations', headers=self.a, json=self.mutation())
        destination = self.directory.name + '/backup.sqlite'
        with module.db() as source, sqlite3.connect(destination) as target:
            source.backup(target)
        with sqlite3.connect(destination) as restored:
            self.assertEqual(restored.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
            self.assertEqual(restored.execute('SELECT COUNT(*) FROM items').fetchone()[0], 1)

    def test_websocket_requires_auth(self):
        with self.client.websocket_connect('/v1/live') as socket:
            socket.send_json({'token': self.a['Authorization'].split(' ')[1]})
            self.assertEqual(socket.receive_json()['cursor'], 0)

if __name__ == '__main__':
    unittest.main()
