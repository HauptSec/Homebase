"""APNs credentials are mounted as files, never committed to the repository."""
import os
import time
from pathlib import Path
import httpx
import jwt

_cached = ('', 0)

async def deliver(token, environment, payload):
    global _cached
    path = os.getenv('APNS_KEY_FILE')
    if not path:
        return 503
    now = time.time()
    if now - _cached[1] > 2400:
        _cached = (jwt.encode({'iss': os.environ['APNS_TEAM_ID'], 'iat': int(now)}, Path(path).read_text(), algorithm='ES256', headers={'kid': os.environ['APNS_KEY_ID']}), now)
    host = 'api.sandbox.push.apple.com' if environment == 'sandbox' else 'api.push.apple.com'
    async with httpx.AsyncClient(http2=True, timeout=15) as client:
        response = await client.post(f'https://{host}/3/device/{token}', json=payload, headers={'authorization': f'bearer {_cached[0]}', 'apns-topic': os.environ['APNS_BUNDLE_ID'], 'apns-push-type': 'alert', 'apns-priority': '10'})
    return response.status_code
