"""Homebase's single-household API. Credentials are device-specific, never user passwords."""
import asyncio
import hashlib
import json
import os
import secrets
import sqlite3
import time
from contextlib import asynccontextmanager, contextmanager
from pathlib import Path
from typing import Literal
from uuid import UUID

from fastapi import Depends, FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, ConfigDict, Field, model_validator

DB_PATH = os.getenv("HOMEBASE_DB", "/data/homebase.sqlite")

@contextmanager
def db():
    connection = sqlite3.connect(DB_PATH, timeout=15)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys=ON")
    try:
        yield connection
        connection.commit()
    except BaseException:
        connection.rollback()
        raise
    finally:
        connection.close()


def initialize():
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    with db() as c:
        c.execute("PRAGMA journal_mode=WAL")
        c.executescript('''
        CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,name TEXT NOT NULL,token_hash TEXT UNIQUE NOT NULL, revoked INTEGER NOT NULL DEFAULT 0,apns_token TEXT,apns_environment TEXT NOT NULL DEFAULT 'production');
        CREATE TABLE IF NOT EXISTS invites(hash TEXT PRIMARY KEY,expires REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS items(id TEXT PRIMARY KEY,revision INTEGER NOT NULL,body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS changes(seq INTEGER PRIMARY KEY AUTOINCREMENT,item_id TEXT NOT NULL,body TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS mutations(device_id TEXT NOT NULL,mutation_id TEXT NOT NULL,result TEXT NOT NULL,PRIMARY KEY(device_id,mutation_id));
        CREATE TABLE IF NOT EXISTS notifications(id INTEGER PRIMARY KEY AUTOINCREMENT,device_id TEXT NOT NULL,body TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,next_attempt REAL NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS reminders(item_id TEXT NOT NULL,reminder_at REAL NOT NULL,PRIMARY KEY(item_id,reminder_at));
        CREATE TABLE IF NOT EXISTS calendar_bridge(singleton INTEGER PRIMARY KEY CHECK(singleton=1),device_id TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS rate_limits(bucket TEXT PRIMARY KEY,starts REAL NOT NULL,count INTEGER NOT NULL);
        ''')


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def rate_limit(bucket, limit, window):
    now = time.time()
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        c.execute("DELETE FROM rate_limits WHERE starts < ?", (now - 3600,))
        row = c.execute("SELECT * FROM rate_limits WHERE bucket=?", (bucket,)).fetchone()
        if not row or row['starts'] + window < now:
            c.execute("INSERT OR REPLACE INTO rate_limits VALUES(?,?,1)", (bucket, now))
        elif row['count'] >= limit:
            raise HTTPException(429, "Too many requests; try again later")
        else:
            c.execute("UPDATE rate_limits SET count=count+1 WHERE bucket=?", (bucket,))


def authenticate(token):
    with db() as c:
        row = c.execute("SELECT * FROM devices WHERE token_hash=? AND revoked=0", (digest(token),)).fetchone()
    if row is None:
        raise HTTPException(401, "Pair this device again")
    return dict(row)


bearer = HTTPBearer(auto_error=False)
def device(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
    if credentials is None:
        raise HTTPException(401, "Device credential required")
    result = authenticate(credentials.credentials)
    rate_limit('device:' + result['id'], 600, 60)
    return result


class Item(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)
    id: UUID
    kind: Literal['event', 'dinner', 'bill', 'task', 'grocery', 'meal']
    title: str = Field(min_length=1, max_length=300)
    notes: str = Field(default='', max_length=10000)
    date: float | None = None
    endDate: float | None = None
    reminderAt: float | None = None
    store: str = Field(default='', max_length=100)
    calendarKey: str = Field(default='', max_length=1000)
    quantity: str = Field(default='', max_length=100)
    amountCents: int | None = Field(default=None, ge=0, le=100000000000)
    currency: str = Field(default='USD', pattern='^[A-Z]{3}$')
    recurrence: Literal['none', 'weekly', 'monthly', 'yearly'] = 'none'
    ingredients: list[str] = Field(default_factory=list, max_length=100)
    paidDates: list[float] = Field(default_factory=list, max_length=10000)
    allDay: bool = False
    done: bool = False
    deleted: bool = False
    revision: int = Field(default=0, ge=0)
    updatedAt: float = 0
    updatedBy: str = ''


    @model_validator(mode='after')
    def check_fields(self):
        if not self.title.strip():
            raise ValueError('Title cannot be blank')
        if self.kind in ('event', 'dinner', 'bill') and self.date is None:
            raise ValueError('This item requires a date')
        if self.kind == 'event' and (self.endDate is None or self.endDate <= self.date):
            raise ValueError('Event end must follow its start')
        if any(len(value) > 300 for value in self.ingredients):
            raise ValueError('Ingredient names must be at most 300 characters')
        return self


class Mutation(BaseModel):
    mutationId: UUID
    baseRevision: int = Field(ge=0)
    item: Item


class PairRequest(BaseModel):
    code: str = Field(min_length=20, max_length=200)
    name: str = Field(min_length=1, max_length=80)


class PushRegistration(BaseModel):
    token: str = Field(pattern='^[a-f0-9]{64,200}$')
    environment: Literal['sandbox', 'production'] = 'production'


def enqueue(c, excluded, message):
    for row in c.execute("SELECT id FROM devices WHERE revoked=0 AND id != ? AND apns_token IS NOT NULL", (excluded,)).fetchall():
        c.execute("INSERT INTO notifications(device_id,body) VALUES(?,?)", (row['id'], json.dumps(message)))


async def notification_worker():
    import logging
    while True:
        try:
            from server.push import deliver
            with db() as c:
                for row in c.execute("SELECT body FROM items").fetchall():
                    item = json.loads(row['body'])
                    due = item.get('reminderAt')
                    if due and due <= time.time() and not item['deleted'] and not item['done']:
                        changed = c.execute("INSERT OR IGNORE INTO reminders VALUES(?,?)", (item['id'], due)).rowcount
                        if changed:
                            enqueue(c, '', {'aps': {'alert': {'title': 'Homebase reminder', 'body': 'Something in your household is due.'}, 'sound': 'default', 'content-available': 1}})
                jobs = c.execute("SELECT n.*,d.apns_token,d.apns_environment,d.revoked FROM notifications n JOIN devices d ON d.id=n.device_id WHERE next_attempt <= ? LIMIT 50", (time.time(),)).fetchall()
            for job in jobs:
                status = 410 if job['revoked'] else await deliver(job['apns_token'], job['apns_environment'], json.loads(job['body']))
                with db() as c:
                    if status in (200, 400, 410) or job['attempts'] >= 10:
                        c.execute("DELETE FROM notifications WHERE id=?", (job['id'],))
                        if status == 410:
                            c.execute("UPDATE devices SET apns_token=NULL WHERE id=?", (job['device_id'],))
                    else:
                        c.execute("UPDATE notifications SET attempts=attempts+1,next_attempt=? WHERE id=?", (time.time() + min(3600, 30 * 2 ** job['attempts']), job['id']))
        except asyncio.CancelledError:
            raise
        except Exception:
            logging.exception("Notification processing failed; will retry")
        await asyncio.sleep(15)


@asynccontextmanager
async def lifespan(app):
    initialize()
    worker = asyncio.create_task(notification_worker())
    yield
    worker.cancel()
    try:
        await worker
    except asyncio.CancelledError:
        pass


app = FastAPI(title='Homebase', docs_url=None, redoc_url=None, openapi_url=None, lifespan=lifespan)


@app.middleware('http')
async def guard(request: Request, call_next):
    # Reject unbounded/chunked mutation bodies before FastAPI parses them.
    if request.method in ('POST', 'PUT', 'PATCH'):
        try:
            length = int(request.headers.get('content-length', '-1'))
        except ValueError:
            length = -1
        if length < 0 or length > 131072:
            from fastapi.responses import JSONResponse
            return JSONResponse({'detail': 'A body of at most 128 KiB is required'}, status_code=413)
    response = await call_next(request)
    response.headers['Cache-Control'] = 'no-store'
    response.headers['X-Content-Type-Options'] = 'nosniff'
    return response


@app.get('/health')
def health():
    with db() as c:
        c.execute('SELECT 1')
    return {'status': 'ok'}


@app.post('/v1/pair')
def pair(payload: PairRequest):
    # Global limit cannot be bypassed by spoofing proxy headers.
    rate_limit('pair', 20, 60)
    from uuid import uuid4
    token, identifier = secrets.token_urlsafe(48), str(uuid4())
    with db() as c:
        c.execute('BEGIN IMMEDIATE')
        invite = c.execute('DELETE FROM invites WHERE hash=? AND expires>? RETURNING hash', (digest(payload.code), time.time())).fetchone()
        if not invite:
            raise HTTPException(403, 'Invalid or expired pairing code')
        c.execute('INSERT INTO devices(id,name,token_hash) VALUES(?,?,?)', (identifier, payload.name, digest(token)))
    return {'token': token, 'deviceId': identifier}


@app.get('/v1/sync')
def sync(after: int = 0, actor=Depends(device)):
    if after < 0:
        raise HTTPException(422, 'Invalid cursor')
    with db() as c:
        rows = c.execute('SELECT seq,body FROM changes WHERE seq>? ORDER BY seq LIMIT 500', (after,)).fetchall()
    return {'cursor': rows[-1]['seq'] if rows else after, 'items': [json.loads(r['body']) for r in rows], 'hasMore': len(rows) == 500}


@app.post('/v1/mutations')
def mutate(payload: Mutation, actor=Depends(device)):
    with db() as c:
        c.execute('BEGIN IMMEDIATE')
        previous = c.execute('SELECT result FROM mutations WHERE device_id=? AND mutation_id=?', (actor['id'], str(payload.mutationId))).fetchone()
        if previous:
            return json.loads(previous['result'])
        current = c.execute('SELECT * FROM items WHERE id=?', (str(payload.item.id),)).fetchone()
        revision = current['revision'] if current else 0
        if revision != payload.baseRevision:
            raise HTTPException(409, {'message': 'This item changed on another device', 'current': json.loads(current['body']) if current else None})
        if current and json.loads(current['body'])['kind'] != payload.item.kind:
            raise HTTPException(422, 'Item type cannot change')
        item = payload.item.model_dump(mode='json')
        item.update(revision=revision + 1, updatedAt=time.time(), updatedBy=actor['id'])
        body = json.dumps(item)
        c.execute('INSERT OR REPLACE INTO items VALUES(?,?,?)', (item['id'], item['revision'], body))
        c.execute('INSERT INTO changes(item_id,body) VALUES(?,?)', (item['id'], body))
        result = {'item': item}
        c.execute('INSERT INTO mutations VALUES(?,?,?)', (actor['id'], str(payload.mutationId), json.dumps(result)))
        enqueue(c, actor['id'], {'aps': {'alert': {'title': 'Homebase', 'body': 'Your household has an update.'}, 'sound': 'default', 'content-available': 1}})
    return result


@app.post('/v1/push')
def register_push(payload: PushRegistration, actor=Depends(device)):
    with db() as c:
        c.execute('UPDATE devices SET apns_token=?,apns_environment=? WHERE id=?', (payload.token, payload.environment, actor['id']))
    return {'ok': True}


@app.websocket('/v1/live')
async def live(socket: WebSocket):
    await socket.accept()
    try:
        # Credentials never appear in access-log URLs.
        data = await asyncio.wait_for(socket.receive_json(), 5)
        token = data.get('token', '')
        authenticate(token)
        last = -1
        for _ in range(1800):
            authenticate(token)  # Revocation applies to existing sockets too.
            with db() as c:
                cursor = c.execute('SELECT COALESCE(MAX(seq),0) FROM changes').fetchone()[0]
            if cursor != last:
                await socket.send_json({'cursor': cursor})
                last = cursor
            await asyncio.sleep(1)
        await socket.close(code=1000)
    except (HTTPException, TimeoutError, ValueError, AttributeError):
        await socket.close(code=1008)
    except (WebSocketDisconnect, RuntimeError):
        pass


@app.post('/v1/calendar/claim')
def claim_calendar(actor=Depends(device)):
    with db() as c:
        c.execute('BEGIN IMMEDIATE')
        c.execute('DELETE FROM calendar_bridge WHERE device_id IN (SELECT id FROM devices WHERE revoked=1)')
        owner = c.execute('SELECT device_id FROM calendar_bridge WHERE singleton=1').fetchone()
        if owner and owner['device_id'] != actor['id']:
            raise HTTPException(409, 'Another phone is the calendar bridge. Release it in Settings first.')
        c.execute('INSERT OR REPLACE INTO calendar_bridge VALUES(1,?)', (actor['id'],))
    return {'ok': True}

@app.post('/v1/calendar/release')
def release_calendar(actor=Depends(device)):
    with db() as c:
        c.execute('DELETE FROM calendar_bridge WHERE device_id=?', (actor['id'],))
    return {'ok': True}
