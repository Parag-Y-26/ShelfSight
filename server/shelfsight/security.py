"""Firebase identity verification and one-use pairing, with no development bypass."""

from __future__ import annotations

import hashlib
import json
import secrets
import threading
import time
from collections import defaultdict, deque
from datetime import UTC, datetime
from typing import Protocol

import cachecontrol
import google.auth.transport.requests
import requests
from fastapi import HTTPException
from google.oauth2 import id_token

from .db import Database


class IdentityVerifier(Protocol):
    def verify(self, token: str) -> str: ...


class FirebaseVerifier:
    def __init__(self, project_id: str):
        self.project_id = project_id
        # Google's cache headers keep public signing keys usable through short network interruptions.
        session = cachecontrol.CacheControl(requests.Session())
        self.request = google.auth.transport.requests.Request(session=session)

    def verify(self, token: str) -> str:
        if not self.project_id:
            raise HTTPException(503, "Firebase project is not configured on the laptop")
        try:
            claims = id_token.verify_firebase_token(token, self.request, audience=self.project_id)
            expected_issuer = f"https://securetoken.google.com/{self.project_id}"
            uid = claims.get("sub", "")
            if (
                claims.get("iss") != expected_issuer
                or claims.get("aud") != self.project_id
                or not isinstance(uid, str)
                or not 0 < len(uid) <= 128
                or claims.get("exp", 0) <= time.time()
                or claims.get("iat", float("inf")) > time.time()
            ):
                raise ValueError("Invalid Firebase claims")
            return uid
        except (ValueError, requests.RequestException, google.auth.exceptions.GoogleAuthError) as exc:
            raise HTTPException(401, "Invalid or expired Firebase ID token") from exc


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def bearer(header: str | None) -> str:
    if not header or not header.startswith("Bearer ") or len(header) > 16384:
        raise HTTPException(401, "Bearer authentication is required")
    token = header[7:].strip()
    if not token:
        raise HTTPException(401, "Bearer authentication is required")
    return token


class RateLimiter:
    """Bound pairing guesses per peer; bounded memory, no identifying data in logs."""

    def __init__(self):
        self.entries: dict[str, deque] = defaultdict(deque)
        self.lock = threading.Lock()

    def check(self, peer: str):
        now = time.monotonic()
        with self.lock:
            if len(self.entries) >= 4096:
                stale = [
                    key for key, values in self.entries.items() if not values or values[-1] < now - 60
                ]
                for key in stale:
                    del self.entries[key]
                if len(self.entries) >= 4096 and peer not in self.entries:
                    raise HTTPException(429, "Pairing is busy; retry shortly")
            values = self.entries[peer]
            while values and values[0] < now - 60:
                values.popleft()
            if len(values) >= 10:
                raise HTTPException(429, "Too many pairing attempts; retry shortly")
            values.append(now)


class Sessions:
    def __init__(self, db: Database, pairing_ttl: int, session_ttl: int):
        self.db = db
        self.pairing_ttl = pairing_ttl
        self.session_ttl = session_ttl

    def issue_pairing(self) -> tuple[str, float]:
        secret, expires = secrets.token_urlsafe(32), time.time() + self.pairing_ttl
        with self.db.transaction():
            self.db.execute("DELETE FROM pairing")  # only the current local pairing code is valid
            self.db.execute("INSERT INTO pairing VALUES (?,?,0)", (token_hash(secret), expires))
        return secret, expires

    def pair(self, secret: str, uid: str, device_name: str) -> dict:
        token, expires = secrets.token_urlsafe(48), time.time() + self.session_ttl
        data = {
            "device_name": device_name,
            "owner_uid": uid,
            "expires_at": datetime.fromtimestamp(expires, UTC).isoformat().replace("+00:00", "Z"),
        }
        with self.db.transaction():
            consumed = self.db.execute(
                "UPDATE pairing SET consumed=1 WHERE secret_hash=? AND consumed=0 AND expires_at>?",
                (token_hash(secret), time.time()),
            )
            if consumed.rowcount != 1:
                raise HTTPException(403, "Pairing code is invalid, expired, or already used")
            self.db.execute(
                "INSERT INTO device_sessions VALUES (?,?,?,?)",
                (token_hash(token), uid, expires, json.dumps(data)),
            )
        return {**data, "session_token": token}

    def resolve(self, token: str) -> dict:
        row = self.db.execute(
            "SELECT * FROM device_sessions WHERE token_hash=? AND expires_at>?",
            (token_hash(token), time.time()),
        ).fetchone()
        if row is None:
            raise HTTPException(401, "Device session is expired or revoked; pair again")
        return json.loads(row["data"])

    def revoke(self, token: str):
        self.db.execute("DELETE FROM device_sessions WHERE token_hash=?", (token_hash(token),))
