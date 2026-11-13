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

    def test_task_completion_attribution_and_history(self):
        with module.db() as c:
            c.execute("UPDATE devices SET owner_name='Laura' WHERE name='Partner'")
        self.assertEqual(self.client.get('/v1/sync', headers=self.b).json()['ownerName'], 'Laura')
        data = self.mutation(kind='task', title='Laundry')
        item = self.client.post('/v1/mutations', headers=self.a, json=data).json()['item']

        def save(item, headers):
            response = self.client.post('/v1/mutations', headers=headers, json={
                'mutationId': str(uuid4()), 'baseRevision': item['revision'], 'item': item})
            self.assertEqual(response.status_code, 200, response.text)
            return response.json()['item']

        completed = time.time() - 3600  # Offline completion is recorded at tap time.
        item.update(done=True, completedAt=completed, completedBy='Alex', completedByDevice='spoof')
        item = save(item, self.b)
        self.assertEqual(item['completedBy'], 'Laura')
        self.assertEqual(item['completedAt'], completed)
        with module.db() as c:
            laura = c.execute("SELECT id FROM devices WHERE name='Partner'").fetchone()['id']
        self.assertEqual(item['completedByDevice'], laura)
        # Older apps omit metadata; unrelated edits must preserve the original completion.
        for field in ('completedAt', 'completedBy', 'completedByDevice'):
            item.pop(field)
        item['notes'] = 'Folded'
        item = save(item, self.a)
        self.assertEqual(item['completedAt'], completed)
        self.assertEqual(item['completedBy'], 'Laura')
        item.update(completedBy='Alex', completedAt=1)
        item = save(item, self.a)
        self.assertEqual(item['completedBy'], 'Laura')
        self.assertEqual(item['completedAt'], completed)
        item['done'] = False
        item = save(item, self.a)
        self.assertIsNone(item['completedAt'])
        self.assertIsNone(item['completedBy'])
        self.assertIsNone(item['completedByDevice'])
        # An older app completing a task still gets authenticated attribution and server time.
        item['done'] = True
        item = save(item, self.a)
        self.assertEqual(item['completedBy'], 'Alex')
        self.assertGreater(item['completedAt'], completed)
        synced = self.client.get('/v1/sync', headers=self.b).json()['items'][-1]
        self.assertEqual(synced, item)

    def test_task_completion_retry_and_unknown_device(self):
        data = self.mutation(kind='task', done=True)
        self.assertEqual(self.client.post('/v1/mutations', headers=self.b, json=data).status_code, 422)
        first = self.client.post('/v1/mutations', headers=self.a, json=data)
        retry = self.client.post('/v1/mutations', headers=self.a, json=data)
        self.assertEqual(first.status_code, 200)
        self.assertEqual(first.json(), retry.json())
        module.initialize()  # Owner migration is safe on existing databases.

    def test_grocery_completion_sync_and_undo(self):
        bought = time.time() - 7200
        data = self.mutation(done=True, completedAt=bought)
        def save():
            response = self.client.post('/v1/mutations', headers=self.b, json=data)
            self.assertEqual(response.status_code, 200, response.text)
            item = response.json()['item']
            data.update(baseRevision=item['revision'], mutationId=str(uuid4()), item=item)
            return item
        self.assertEqual(save()['completedAt'], bought)
        data['item'].pop('completedAt')
        data['item']['notes'] = 'Different size'
        self.assertEqual(save()['completedAt'], bought)
        data['item']['done'] = False
        self.assertIsNone(save()['completedAt'])
        data['item']['done'] = True
        self.assertGreater(save()['completedAt'], bought)
        latest = self.client.get('/v1/sync', headers=self.a).json()['items'][-1]
        self.assertEqual(latest, data['item'])

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

    def test_budget_income_and_legacy_edits(self):
        data = self.mutation(kind='bill', title='Paycheck', date=1793811600,
                             budgetType='income', amountCents=250000, recurrence='biweekly')
        response = self.client.post('/v1/mutations', headers=self.a, json=data)
        self.assertEqual(response.status_code, 200)
        income = response.json()['item']
        self.assertEqual(income['budgetType'], 'income')
        self.assertEqual(income['recurrence'], 'biweekly')
        income.pop('budgetType')  # Simulate an older app saving an unrelated edit.
        income['notes'] = 'Updated note'
        response = self.client.post('/v1/mutations', headers=self.b, json={
            'mutationId': str(uuid4()), 'baseRevision': 1, 'item': income})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['item']['budgetType'], 'income')
        invalid = self.mutation(kind='bill', date=1793811600, budgetType='transfer')
        self.assertEqual(self.client.post('/v1/mutations', headers=self.a, json=invalid).status_code, 422)

    def test_meal_steps_sync_and_legacy_edit(self):
        data = self.mutation(kind='dinner', title='Roast chicken', date=1793811600,
                             ingredients=['Chicken', 'Salt'], prepSteps=['Season chicken'],
                             cookingSteps=['Roast until cooked', 'Rest before serving'])
        response = self.client.post('/v1/mutations', headers=self.a, json=data)
        self.assertEqual(response.status_code, 200)
        meal = response.json()['item']
        synced = self.client.get('/v1/sync', headers=self.b).json()['items'][-1]
        self.assertEqual(synced['cookingSteps'], data['item']['cookingSteps'])
        meal.pop('prepSteps'); meal.pop('cookingSteps')
        response = self.client.post('/v1/mutations', headers=self.b, json={
            'mutationId': str(uuid4()), 'baseRevision': 1, 'item': meal})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['item']['prepSteps'], ['Season chicken'])
        self.assertEqual(response.json()['item']['cookingSteps'], data['item']['cookingSteps'])
        meal = response.json()['item']; meal['prepSteps'] = []; meal['cookingSteps'] = []
        response = self.client.post('/v1/mutations', headers=self.a, json={
            'mutationId': str(uuid4()), 'baseRevision': 2, 'item': meal})
        self.assertEqual(response.json()['item']['cookingSteps'], [])
        invalid = self.mutation(kind='meal', prepSteps=['x' * 301])
        self.assertEqual(self.client.post('/v1/mutations', headers=self.a, json=invalid).status_code, 422)

    def test_recurring_events_exceptions_and_field_clears(self):
        version = str(uuid4())
        data = self.mutation(kind='event', title='Weekly plan', date=1793811600, endDate=1793815200,
                             recurrence='custom', customFrequency='weekly', customInterval=2,
                             repeatWeekdays=[2,4], recurrenceUntil=1800000000,
                             recurrenceTimeZone='America/Los_Angeles', seriesVersion=version,
                             location='123 Main Street', latitude=34, longitude=-118, alertOffsets=[-900,0])
        response = self.client.post('/v1/mutations', headers=self.a, json=data)
        self.assertEqual(response.status_code, 200, response.text)
        root = response.json()['item']
        occurrence = self.mutation(kind='event', title='Moved instance', date=1793818800, endDate=1793822400,
                                   seriesID=root['id'], seriesVersion=version, occurrenceDate=1793811600)
        result = self.client.post('/v1/mutations', headers=self.b, json=occurrence)
        self.assertEqual(result.status_code, 200, result.text)
        root.update(recurrenceUntil=None, latitude=None, longitude=None, location='', alertOffsets=[])
        result = self.client.post('/v1/mutations', headers=self.a, json={'mutationId':str(uuid4()), 'baseRevision':1, 'item':root})
        self.assertEqual(result.status_code, 200, result.text)
        root = result.json()['item']
        self.assertIsNone(root['recurrenceUntil']); self.assertIsNone(root['latitude'])
        self.assertEqual(root['alertOffsets'], [])
        # A late offline occurrence edit must not reappear after the series was deleted.
        root['deleted'] = True
        self.assertEqual(self.client.post('/v1/mutations', headers=self.a, json={'mutationId':str(uuid4()), 'baseRevision':2, 'item':root}).status_code, 200)
        occurrence['mutationId'] = str(uuid4()); occurrence['baseRevision'] = 1
        self.assertEqual(self.client.post('/v1/mutations', headers=self.b, json=occurrence).status_code, 409)

    def test_event_repeat_and_alert_validation(self):
        for fields in [dict(recurrence='custom'), dict(alertOffsets=[0,-60,-120]), dict(alertOffsets=[0,0]),
                       dict(alertOffsets=[60]), dict(repeatWeekdays=[8]), dict(recurrenceTimeZone='Not/AZone'),
                       dict(recurrenceUntil=1)]:
            data = self.mutation(kind='event', date=1793811600, endDate=1793815200, **fields)
            self.assertEqual(self.client.post('/v1/mutations', headers=self.a, json=data).status_code, 422, fields)

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
