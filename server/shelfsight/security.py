"""Supabase identity verification and one-use pairing, with no development bypass."""

from __future__ import annotations

import hashlib
import json
import secrets
import threading
import time
from collections import defaultdict, deque
from datetime import UTC, datetime
from typing import Protocol

import httpx
from fastapi import HTTPException

from .db import Database


class IdentityVerifier(Protocol):
    def verify(self, token: str) -> str: ...


class SupabaseVerifier:
    # Validate bearer access tokens with the trusted Supabase Auth endpoint over TLS.
    def __init__(self, project_url: str, publishable_key: str):
        self.project_url = project_url.rstrip("/")
        self.publishable_key = publishable_key

    def verify(self, token: str) -> str:
        if not self.project_url or not self.publishable_key:
            raise HTTPException(503, "Supabase Auth is not configured on the server")
        try:
            response = httpx.get(
                f"{self.project_url}/auth/v1/user",
                headers={"apikey": self.publishable_key, "Authorization": f"Bearer {token}"},
                timeout=5.0,
            )
        except httpx.TimeoutException as exc:
            raise HTTPException(503, "Supabase Auth verification timed out") from exc
        except httpx.RequestError as exc:
            raise HTTPException(503, "Supabase Auth is temporarily unavailable") from exc
        if response.status_code in (400, 401, 403):
            raise HTTPException(401, "Invalid or expired Supabase access token")
        if response.status_code != 200:
            raise HTTPException(503, "Supabase Auth verification failed")
        try:
            user_id = response.json().get("id")
            if not isinstance(user_id, str) or not user_id or len(user_id) > 128:
                raise ValueError("Missing Supabase user id")
            return user_id
        except (ValueError, AttributeError) as exc:
            raise HTTPException(401, "Invalid Supabase user response") from exc


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
        with self.db.transaction():
            consumed = self.db.execute(
                "UPDATE pairing SET consumed=1 WHERE secret_hash=? AND consumed=0 AND expires_at>?",
                (token_hash(secret), time.time()),
            )
            if consumed.rowcount != 1:
                raise HTTPException(403, "Pairing code is invalid, expired, or already used")
            return self.issue_authenticated(uid, device_name)

    def issue_authenticated(self, uid: str, device_name: str) -> dict:
        """Caller must verify Supabase identity or consume a local pairing proof first."""
        token, expires = secrets.token_urlsafe(48), time.time() + self.session_ttl
        data = {
            "device_name": device_name,
            "owner_uid": uid,
            "expires_at": datetime.fromtimestamp(expires, UTC).isoformat().replace("+00:00", "Z"),
        }
        self.db.execute("DELETE FROM device_sessions WHERE expires_at<=?", (time.time(),))
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
