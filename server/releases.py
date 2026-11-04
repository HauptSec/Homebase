"""Ad hoc downloads: expiring, build-specific grants; never household credentials in URLs."""
import hashlib
import html
import json
import os
import plistlib
import secrets
import time
from pathlib import Path
from urllib.parse import quote, urlencode
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import HTMLResponse, FileResponse, Response
from pydantic import BaseModel, ConfigDict, Field
from server.app import db, device, digest, enqueue

router = APIRouter()
RELEASES = Path(os.getenv('HOMEBASE_RELEASES', '/releases'))
PUBLIC_URL = os.getenv('HOMEBASE_PUBLIC_URL', 'https://homebase.hauptsec.xyz').rstrip('/')

class Release(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)
    build: int = Field(ge=2, le=9999)
    version: str = Field(pattern=r'^\d+\.\d+(?:\.\d+)?$')
    bundleId: str = Field(pattern=r'^xyz\.hauptsec\.homebase$')
    sha256: str = Field(pattern=r'^[a-f0-9]{64}$')
    size: int = Field(gt=0, le=536870912)
    expiresAt: float = Field(gt=0)
    notes: str = Field(max_length=5000)
    sourceCommit: str = Field(pattern=r'^[a-f0-9]{40}$')
    deviceCount: int = Field(ge=1, le=100)


def latest():
    with db() as c:
        row = c.execute('SELECT metadata FROM app_releases ORDER BY build DESC LIMIT 1').fetchone()
    return Release.model_validate_json(row['metadata']) if row else None


def publish(build):
    folder = RELEASES / str(int(build))
    release = Release.model_validate_json((folder / 'release.json').read_text())
    if release.build != int(build) or release.expiresAt < time.time() + 86400:
        raise ValueError('Build mismatch or signing validity under one day')
    package = folder / 'Homebase.ipa'
    if package.stat().st_size != release.size:
        raise ValueError('Package size mismatch')
    with package.open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != release.sha256:
            raise ValueError('Package checksum mismatch')
    encoded = release.model_dump_json()
    with db() as c:
        c.execute('BEGIN IMMEDIATE')
        previous = c.execute('SELECT metadata FROM app_releases WHERE build=?', (release.build,)).fetchone()
        if previous:
            if Release.model_validate_json(previous['metadata']) != release:
                raise ValueError('A published build is immutable')
            return
        highest = c.execute('SELECT COALESCE(MAX(build),1) FROM app_releases').fetchone()[0]
        if release.build <= highest:
            raise ValueError('Build number must increase')
        c.execute('INSERT INTO app_releases VALUES(?,?,?)', (release.build, encoded, time.time()))
        enqueue(c, '', {'aps': {'alert': {'title': 'Homebase update available', 'body': 'Open Household → Settings → App updates to install.'}, 'sound': 'default', 'content-available': 1}})


def issue_ticket(actor_id=None):
    release = latest()
    if not release or release.expiresAt <= time.time():
        raise HTTPException(404, 'No unexpired release is available')
    ticket = secrets.token_urlsafe(32)
    expires = time.time() + 3600
    with db() as c:
        c.execute('DELETE FROM install_tickets WHERE expires<?', (time.time(),))
        c.execute('INSERT INTO install_tickets VALUES(?,?,?,?)', (digest(ticket), release.build, expires, actor_id))
    return {'url': PUBLIC_URL + '/install?' + urlencode({'ticket': ticket}), 'expiresAt': expires}


def authorize(ticket):
    if not ticket or len(ticket) > 100:
        raise HTTPException(403, 'Open a fresh install link from Homebase Settings')
    with db() as c:
        row = c.execute('SELECT t.*,r.metadata FROM install_tickets t JOIN app_releases r ON r.build=t.build WHERE t.hash=? AND t.expires>?', (digest(ticket), time.time())).fetchone()
        if not row:
            raise HTTPException(403, 'Install link expired; open a fresh link from Homebase Settings')
        if row['device_id']:
            active = c.execute('SELECT 1 FROM devices WHERE id=? AND revoked=0', (row['device_id'],)).fetchone()
            if not active:
                raise HTTPException(403, 'Device access revoked')
    release = Release.model_validate_json(row['metadata'])
    if release.expiresAt <= time.time():
        raise HTTPException(410, 'This signed build has expired')
    return release


@router.get('/v1/releases/latest')
def release_info(actor=Depends(device)):
    release = latest()
    return {'release': release.model_dump() if release and release.expiresAt > time.time() else None}


@router.post('/v1/releases/link')
def release_link(actor=Depends(device)):
    return issue_ticket(actor['id'])


@router.get('/install', response_class=HTMLResponse)
def install(ticket: str = ''):
    if ticket:
        release = authorize(ticket)
        manifest = PUBLIC_URL + '/install/manifest.plist?' + urlencode({'ticket': ticket})
        href = 'itms-services://?action=download-manifest&url=' + quote(manifest, safe='')
        expiry = datetime.fromtimestamp(release.expiresAt, timezone.utc).strftime('%B %d, %Y')
        content = f'''<p class="eyebrow">PRIVATE IPHONE RELEASE</p><h1>A little more<br>life in order.</h1>
        <p>Homebase {html.escape(release.version)} · Build {release.build}</p>
        <a class="button" href="{html.escape(href, quote=True)}">Install update</a>
        <p>Open this page in Safari on your registered iPhone, tap Install update, and confirm the iOS prompt. Then return to your Home Screen.</p>
        <h2>What’s new</h2><p class="notes">{html.escape(release.notes)}</p>
        <p class="small">This link lasts one hour. This build is signed through {expiry} (UTC). Only registered phones can install it. Sync any pending Homebase edits before updating. Do not delete the existing app.</p>'''
    else:
        content = '<p class="eyebrow">YOUR PRIVATE HOUSEHOLD</p><h1>Homebase updates.</h1><p>On a paired phone, open <strong>Household → Settings → App updates</strong> for a secure install link.</p><p>Installing for the first time? Ask your household administrator for a temporary download link. Your iPhone must be registered for this release.</p>'
    body = '''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>Homebase · Updates</title><style>
    :root{color-scheme:light dark;--bg:#f6f4ef;--fg:#27372e;--muted:#62685f;--accent:#506858;--card:#fff}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:17px/1.6 -apple-system,BlinkMacSystemFont,Arial,sans-serif}main{max-width:580px;margin:8vh auto;padding:32px}header{font-weight:650;letter-spacing:-.02em;margin-bottom:54px}.eyebrow{font-size:11px;letter-spacing:.18em;color:var(--muted)}h1{font:500 44px/1.1 Georgia,serif;letter-spacing:-.03em;margin:20px 0 28px}h2{font-size:17px;margin-top:32px}p{color:var(--muted)}.button{display:block;text-align:center;background:var(--accent);color:white;text-decoration:none;padding:16px;border-radius:16px;margin:24px 0;font-weight:600}.small{font-size:13px}.notes{white-space:pre-wrap}@media(prefers-color-scheme:dark){:root{--bg:#141915;--fg:#e8ede5;--muted:#abb8aa;--accent:#506858;--card:#202720}}
    </style></head><body><main><header>⌂ &nbsp; Homebase</header>''' + content + '</main></body></html>'
    return HTMLResponse(body, headers={'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'", 'X-Robots-Tag': 'noindex, nofollow'})


@router.get('/install/manifest.plist')
def manifest(ticket: str = ''):
    release = authorize(ticket)
    payload = {'items': [{'assets': [{'kind': 'software-package', 'url': PUBLIC_URL + '/install/package.ipa?' + urlencode({'ticket': ticket})}], 'metadata': {'bundle-identifier': release.bundleId, 'bundle-version': str(release.build), 'kind': 'software', 'title': 'Homebase'}}]}
    return Response(plistlib.dumps(payload), media_type='application/xml', headers={'Referrer-Policy': 'no-referrer'})


@router.get('/install/package.ipa')
def package(ticket: str = ''):
    release = authorize(ticket)
    path = RELEASES / str(release.build) / 'Homebase.ipa'
    if not path.is_file():
        raise HTTPException(503, 'Release package is unavailable')
    return FileResponse(path, media_type='application/octet-stream', filename='Homebase.ipa', headers={'Referrer-Policy': 'no-referrer'})
