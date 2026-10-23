"""SQLite persistence with owner-scoped objects and append-only observations."""

from __future__ import annotations

import json
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

from fastapi import HTTPException


def utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def identifier() -> str:
    return uuid.uuid4().hex


class Database:
    def __init__(self, path: Path | str):
        if str(path) != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.connection = sqlite3.connect(str(path), check_same_thread=False, isolation_level=None)
        self.connection.row_factory = sqlite3.Row
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA foreign_keys=ON")
        self.connection.executescript("""
            CREATE TABLE IF NOT EXISTS objects (
              id TEXT PRIMARY KEY, kind TEXT NOT NULL, owner TEXT NOT NULL,
              store_id TEXT NOT NULL, parent_id TEXT, data TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS objects_owner_store ON objects(owner,store_id,kind);
            CREATE TABLE IF NOT EXISTS events (
              id TEXT PRIMARY KEY, owner TEXT NOT NULL, store_id TEXT NOT NULL,
              kind TEXT NOT NULL, at TEXT NOT NULL, data TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS events_store ON events(owner,store_id,at);
            CREATE TRIGGER IF NOT EXISTS events_immutable BEFORE UPDATE ON events
              BEGIN SELECT RAISE(ABORT,'Observation events are append-only'); END;
            CREATE TABLE IF NOT EXISTS device_sessions (
              token_hash TEXT PRIMARY KEY, owner TEXT NOT NULL, expires_at REAL NOT NULL,
              data TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS pairing (
              secret_hash TEXT PRIMARY KEY, expires_at REAL NOT NULL, consumed INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS product_cache (
              barcode TEXT PRIMARY KEY, cached_at TEXT NOT NULL, data TEXT NOT NULL
            );
            PRAGMA user_version=1;
        """)

    @contextmanager
    def transaction(self):
        with self.lock:
            self.connection.execute("BEGIN IMMEDIATE")
            try:
                yield
                self.connection.execute("COMMIT")
            except BaseException:
                self.connection.execute("ROLLBACK")
                raise

    def execute(self, sql: str, args: tuple = ()):
        with self.lock:
            return self.connection.execute(sql, args)

    def create(
        self, kind: str, owner: str, store_id: str, data: dict, parent: str | None = None
    ) -> dict:
        obj = {**data, "id": identifier(), "created_at": utc_now()}
        if kind != "store":
            obj["store_id"] = store_id
        else:
            store_id = obj["id"]
        self.execute(
            "INSERT INTO objects VALUES (?,?,?,?,?,?)",
            (obj["id"], kind, owner, store_id, parent, json.dumps(obj)),
        )
        return obj

    def get(self, kind: str, object_id: str, owner: str) -> dict:
        row = self.execute(
            "SELECT data FROM objects WHERE id=? AND kind=? AND owner=?", (object_id, kind, owner)
        ).fetchone()
        if row is None:
            raise HTTPException(404, "Resource not found")
        return json.loads(row["data"])

    def list(self, kind: str, owner: str, store_id: str | None = None) -> list[dict]:
        sql, args = "SELECT data FROM objects WHERE kind=? AND owner=?", (kind, owner)
        if store_id is not None:
            sql += " AND store_id=?"
            args += (store_id,)
        sql += " ORDER BY rowid"
        return [json.loads(row["data"]) for row in self.execute(sql, args).fetchall()]

    def update(self, kind: str, object_id: str, owner: str, changes: dict) -> dict:
        previous = self.get(kind, object_id, owner)
        updated = {**previous, **changes, "updated_at": utc_now()}
        self.execute(
            "UPDATE objects SET data=?,parent_id=COALESCE(?,parent_id) WHERE id=? AND owner=?",
            (json.dumps(updated), changes.get("floor_id"), object_id, owner),
        )
        return updated

    def event(self, owner: str, store_id: str, kind: str, payload: dict) -> dict:
        event = {
            **payload,
            "id": identifier(),
            "type": kind,
            "store_id": store_id,
            "server_timestamp": utc_now(),
        }
        self.execute(
            "INSERT INTO events VALUES (?,?,?,?,?,?)",
            (event["id"], owner, store_id, kind, event["server_timestamp"], json.dumps(event)),
        )
        return event

    def events(self, owner: str, store_id: str) -> list[dict]:
        return [
            json.loads(row["data"])
            for row in self.execute(
                "SELECT data FROM events WHERE owner=? AND store_id=? ORDER BY rowid", (owner, store_id)
            ).fetchall()
        ]

    def delete_store(self, owner: str, store_id: str) -> None:
        self.get("store", store_id, owner)
        with self.transaction():
            self.execute("DELETE FROM events WHERE owner=? AND store_id=?", (owner, store_id))
            self.execute("DELETE FROM objects WHERE owner=? AND store_id=?", (owner, store_id))

    def close(self):
        self.connection.close()
