"""Authenticated, owner-scoped ShelfSight API and bounded frame processing."""

import asyncio
import json
import math
import secrets
import time
from contextlib import asynccontextmanager
from datetime import timedelta
from typing import Annotated

import cv2
from fastapi import Depends, FastAPI, File, Header, HTTPException, Query, Request, UploadFile, WebSocket
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool
from starlette.websockets import WebSocketDisconnect

from .analytics import export_csv, parse_time, summarize
from .config import BusinessConfig, Settings
from .db import Database, utc_now
from .providers import (
    CatalogRepository,
    Detector,
    DisabledDecisionEngine,
    GeminiVisionModel,
    MediaPipeDetector,
    VisionModel,
    base64_image,
    decode_image,
)
from .schemas import (
    CalibrationInput,
    CloudSessionInput,
    FloorInput,
    FloorPatch,
    FrameInput,
    ItemInput,
    ItemPatch,
    MonitoringInput,
    PairInput,
    ProductInput,
    ProductPatch,
    ShelfInput,
    ShelfPatch,
    StoreInput,
    StorePatch,
)
from .security import FirebaseVerifier, IdentityVerifier, RateLimiter, Sessions, bearer
from .tracking import ZoneTracker, timestamp


class BoundedBody:
    """Reject oversized bodies before FastAPI/multipart parses them, including chunked requests."""

    def __init__(self, app, maximum: int):
        self.app, self.maximum = app, maximum

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] not in {"POST", "PUT", "PATCH"}:
            return await self.app(scope, receive, send)
        body, received = [], 0
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            received += len(message.get("body", b""))
            if received > self.maximum:
                await JSONResponse({"detail": "Request exceeds configured size limit"}, 413)(
                    scope, receive, send
                )
                return
            body.append(message.get("body", b""))
            if not message.get("more_body", False):
                break
        complete = b"".join(body)
        delivered = False

        async def replay():
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": complete, "more_body": False}
            return await receive()

        return await self.app(scope, replay, send)


class MonitorRuntime:
    def __init__(self, session: dict, calibration: dict):
        self.session, self.calibration = session, calibration
        self.tracker = ZoneTracker(
            calibration["zones"], session["thresholds"], session["shelf_thresholds"]
        )
        self.last_capture: float | None = None
        self.sequence = -1
        self.lock = asyncio.Lock()
        self.connected = False
        self.frames, self.bytes = 0, 0
        self.processing_ms: list[float] = []

    def stats(self) -> dict:
        timings = sorted(self.processing_ms)
        return {
            "frames": self.frames,
            "bytes": self.bytes,
            "cloud_requests": 0,
            "p95_processing_ms": timings[max(0, math.ceil(len(timings) * 0.95) - 1)]
            if timings
            else None,
        }


def create_app(
    settings: Settings | None = None,
    *,
    db: Database | None = None,
    verifier: IdentityVerifier | None = None,
    detector: Detector | None = None,
    vision: VisionModel | None = None,
) -> FastAPI:
    settings = settings or Settings()
    config = BusinessConfig(settings.config_path)
    db = db or Database(settings.runtime_dir / "shelfsight.sqlite3")
    sessions = Sessions(
        db, config.data["limits"]["pairing_ttl_seconds"], config.data["limits"]["session_ttl_seconds"]
    )
    verifier = verifier or FirebaseVerifier(settings.firebase_project_id)
    detector = detector or MediaPipeDetector(settings)
    vision = vision or GeminiVisionModel(settings, config)
    catalog = CatalogRepository(db, settings)
    decision = DisabledDecisionEngine()
    limiter = RateLimiter()
    runtimes: dict[str, MonitorRuntime] = {}
    scan_lock = asyncio.Semaphore(1)
    stream_tickets: dict[str, tuple[str, str, float]] = {}

    def capabilities() -> dict:
        values = config.data["capabilities"].copy()
        values["visits"] = values["visits"] and detector.available
        values["dwell"] = values["dwell"] and detector.available
        values["shelf_scan"] = vision.available
        return values

    def provenance(session: dict | None = None, calibration: dict | None = None) -> dict:
        return {
            "provenance": "local_camera_observation" if session else "user_input",
            "config_revision": config.data["revision"],
            "calibration_revision": calibration.get("revision") if calibration else None,
            "calibration_id": calibration.get("id") if calibration else None,
            "session_id": session.get("id") if session else None,
        }

    def ledger_visit(uid: str, runtime: MonitorRuntime, visits: list[dict]) -> list[dict]:
        return [
            db.event(
                uid,
                runtime.session["store_id"],
                "visit",
                {**visit, **provenance(runtime.session, runtime.calibration), "owner_uid": uid},
            )
            for visit in visits
        ]

    def finish(uid: str, session_id: str, incomplete: bool) -> dict:
        session = db.get("monitoring", session_id, uid)
        if session["status"] != "active":
            return session
        runtime = runtimes.get(session_id)
        with db.transaction():
            if runtime:
                ledger_visit(uid, runtime, runtime.tracker.finish(incomplete))
            result = db.update(
                "monitoring",
                session_id,
                uid,
                {
                    "status": "interrupted" if incomplete else "stopped",
                    "ended_at": utc_now(),
                    "incomplete": incomplete,
                    "active_tracks": [],
                    "frames": runtime.frames if runtime else session.get("frames", 0),
                    "bytes": runtime.bytes if runtime else session.get("bytes", 0),
                    "stats": runtime.stats() if runtime else session.get("stats", {}),
                },
            )
        return result

    def recover_interrupted_sessions():
        # Recover finalized coverage and the last durably observed visit state, never bridge downtime.
        rows = db.execute("SELECT owner,data FROM objects WHERE kind='monitoring'").fetchall()
        for row in rows:
            session = json.loads(row["data"])
            if session["status"] != "active":
                continue
            with db.transaction():
                for track in session.get("active_tracks", []):
                    threshold = session["shelf_thresholds"].get(track["shelf_id"], session["thresholds"])
                    if track["dwell_seconds"] >= threshold["dwell_seconds"]:
                        db.event(
                            row["owner"],
                            session["store_id"],
                            "visit",
                            {
                                **track,
                                "incomplete": True,
                                "owner_uid": row["owner"],
                                "provenance": "recovered_local_camera_observation",
                                "config_revision": session["config_revision"],
                                "calibration_id": session["calibration_id"],
                                "calibration_revision": session["calibration_revision"],
                                "session_id": session["id"],
                            },
                        )
                db.update(
                    "monitoring",
                    session["id"],
                    row["owner"],
                    {
                        "status": "interrupted",
                        "incomplete": True,
                        "active_tracks": [],
                        "ended_at": utc_now(),
                    },
                )

    @asynccontextmanager
    async def lifespan(app):
        recover_interrupted_sessions()
        yield
        for session_id, runtime in list(runtimes.items()):
            async with runtime.lock:
                finish(runtime.session["owner_uid"], session_id, True)

    app = FastAPI(
        title="ShelfSight Local Server",
        version="0.1.0",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
    )
    app.add_middleware(BoundedBody, maximum=config.data["limits"]["max_image_bytes"] * 4 // 3 + 65536)
    app.state.db, app.state.config, app.state.sessions = db, config, sessions
    app.state.runtimes, app.state.detector = runtimes, detector
    app.state.verifier = verifier

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, exc: RequestValidationError):
        # Pydantic errors normally include the raw invalid input; never echo uploaded images or secrets.
        return JSONResponse(
            {
                "detail": [
                    {"loc": list(error["loc"]), "msg": error["msg"], "type": error["type"]}
                    for error in exc.errors()
                ]
            },
            422,
        )

    @app.exception_handler(Exception)
    async def unexpected_error(request: Request, exc: Exception):
        return JSONResponse({"detail": "Local server operation failed"}, 500)

    def owner(authorization: Annotated[str | None, Header()] = None) -> str:
        return sessions.resolve(bearer(authorization))["owner_uid"]

    Owner = Annotated[str, Depends(owner)]

    def check_options(data: dict):
        for field, group in (
            ("type_id", "store_types"),
            ("goal_id", "goals"),
            ("currency", "currencies"),
            ("unit", "units"),
            ("shape", "shapes"),
        ):
            if data.get(field) is not None and not config.allows(group, data[field]):
                raise HTTPException(422, f"Unsupported {field}; reload configuration")
        if "settings" in data:
            try:
                config.validate_overrides(data["settings"])
            except ValueError as exc:
                raise HTTPException(422, str(exc)) from exc

    def patch_data(payload) -> dict:
        values = payload.model_dump(exclude_unset=True)
        if any(value is None for value in values.values()):
            raise HTTPException(422, "Required fields cannot be cleared")
        return values

    @app.get("/health")
    def health():
        return {"status": "ok", "version": "0.1.0"}

    @app.post("/v1/pair")
    def pair(
        payload: PairInput, request: Request, authorization: Annotated[str | None, Header()] = None
    ):
        limiter.check(request.client.host if request.client else "unknown")
        uid = app.state.verifier.verify(bearer(authorization))
        return {
            **sessions.pair(payload.pairing_secret, uid, payload.device_name),
            "capabilities": capabilities(),
        }

    @app.post("/v1/cloud-session")
    def cloud_session(
        payload: CloudSessionInput,
        request: Request,
        authorization: Annotated[str | None, Header()] = None,
    ):
        if not settings.cloud_mode:
            raise HTTPException(404, "Cloud login is disabled on the local server")
        limiter.check(request.client.host if request.client else "unknown")
        uid = app.state.verifier.verify(bearer(authorization))
        return {**sessions.issue_authenticated(uid, payload.device_name), "capabilities": capabilities()}

    @app.get("/v1/session")
    def current_session(uid: Owner, authorization: Annotated[str | None, Header()] = None):
        return {**sessions.resolve(bearer(authorization)), "capabilities": capabilities()}

    @app.delete("/v1/session", status_code=204)
    async def revoke_session(uid: Owner, authorization: Annotated[str | None, Header()] = None):
        for session_id, runtime in list(runtimes.items()):
            if runtime.session["owner_uid"] == uid:
                async with runtime.lock:
                    finish(uid, session_id, True)
        sessions.revoke(bearer(authorization))
        return Response(status_code=204)

    @app.get("/v1/config")
    def configuration(uid: Owner):
        return {
            **config.public(),
            "capabilities": capabilities(),
            "providers": {
                "detector": {"available": detector.available, "reason": detector.reason},
                "vision": {"available": vision.available, "reason": vision.reason},
                "product_lookup": {"available": catalog.available, "reason": catalog.reason},
                "decision_engine": {"available": decision.available, "reason": decision.reason},
            },
        }

    @app.get("/v1/stores")
    def stores(uid: Owner):
        return {"items": db.list("store", uid)}

    @app.post("/v1/stores", status_code=201)
    def create_store(payload: StoreInput, uid: Owner):
        values = payload.model_dump()
        check_options(values)
        floor_data, shelf_count = values.pop("floor"), values.pop("shelf_count")
        with db.transaction():
            store = db.create("store", uid, "", {**values, "settings": {}})
            floor = db.create("floor", uid, store["id"], floor_data)
            for index in range(shelf_count):
                db.create(
                    "shelf",
                    uid,
                    store["id"],
                    {
                        "name": config.data["shelf_name_template"].format(n=index + 1),
                        "floor_id": floor["id"],
                        "shape": config.data["shapes"][0]["id"],
                        "x": None,
                        "y": None,
                        "width": None,
                        "length": None,
                        "rotation": 0,
                        "rows": None,
                        "settings": {},
                    },
                    floor["id"],
                )
        return store

    @app.get("/v1/stores/{store_id}/snapshot")
    def snapshot(store_id: str, uid: Owner):
        store = db.get("store", store_id, uid)
        return {
            "store": store,
            **{
                key: db.list(kind, uid, store_id)
                for key, kind in {
                    "floors": "floor",
                    "shelves": "shelf",
                    "products": "product",
                    "items": "item",
                    "calibrations": "calibration",
                }.items()
            },
        }

    @app.patch("/v1/stores/{store_id}")
    def update_store(store_id: str, payload: StorePatch, uid: Owner):
        changes = patch_data(payload)
        check_options(changes)
        with db.transaction():
            store = db.get("store", store_id, uid)
            if changes.get("unit", store["unit"]) != store["unit"]:
                # Physical conversion factors are unit definitions, not store-specific business data.
                meters = {"m": 1.0, "ft": 0.3048}
                scale = meters[store["unit"]] / meters[changes["unit"]]
                for kind in ("floor", "shelf"):
                    for obj in db.list(kind, uid, store_id):
                        geometry = {
                            key: obj[key] * scale
                            for key in ("x", "y", "width", "length")
                            if obj.get(key) is not None
                        }
                        db.update(kind, obj["id"], uid, geometry)
            return db.update("store", store_id, uid, changes)

    @app.delete("/v1/stores/{store_id}", status_code=204)
    async def delete_store(store_id: str, uid: Owner):
        db.get("store", store_id, uid)
        for session_id, runtime in list(runtimes.items()):
            if runtime.session["owner_uid"] == uid and runtime.session["store_id"] == store_id:
                async with runtime.lock:
                    finish(uid, session_id, True)
                    runtimes.pop(session_id, None)
        db.delete_store(uid, store_id)
        return Response(status_code=204)

    @app.post("/v1/stores/{store_id}/floors", status_code=201)
    def create_floor(store_id: str, payload: FloorInput, uid: Owner):
        db.get("store", store_id, uid)
        return db.create("floor", uid, store_id, payload.model_dump())

    def validate_geometry(shelf: dict, floor: dict):
        keys = ("x", "y", "width", "length")
        if any(shelf.get(key) is None for key in keys):
            if any(shelf.get(key) is not None for key in keys):
                raise HTTPException(422, "Provide x, y, width and length together to place a shelf")
            return
        width, length = shelf["width"], shelf["length"]
        if shelf.get("shape") == "square" and abs(width - length) > 1e-8:
            raise HTTPException(422, "Square shelves require equal width and length")
        if shelf.get("rotation", 0) in (90, 270):
            width, length = length, width
        if shelf["x"] + width > floor["width"] or shelf["y"] + length > floor["length"]:
            raise HTTPException(422, "Shelf must fit within the floor")

    @app.patch("/v1/floors/{floor_id}")
    def update_floor(floor_id: str, payload: FloorPatch, uid: Owner):
        changes = patch_data(payload)
        with db.transaction():
            floor = db.get("floor", floor_id, uid)
            for shelf in db.list("shelf", uid, floor["store_id"]):
                if shelf["floor_id"] == floor_id:
                    validate_geometry(shelf, {**floor, **changes})
            return db.update("floor", floor_id, uid, changes)

    @app.post("/v1/stores/{store_id}/shelves", status_code=201)
    def create_shelf(store_id: str, payload: ShelfInput, uid: Owner):
        db.get("store", store_id, uid)
        floor = db.get("floor", payload.floor_id, uid)
        if floor["store_id"] != store_id:
            raise HTTPException(422, "Floor belongs to a different store")
        return db.create(
            "shelf",
            uid,
            store_id,
            {
                **payload.model_dump(),
                "settings": {},
                "shape": config.data["shapes"][0]["id"],
                "x": None,
                "y": None,
                "width": None,
                "length": None,
                "rotation": 0,
                "rows": None,
            },
            floor["id"],
        )

    @app.patch("/v1/shelves/{shelf_id}")
    def update_shelf(shelf_id: str, payload: ShelfPatch, uid: Owner):
        changes = patch_data(payload)
        check_options(changes)
        with db.transaction():
            shelf = db.get("shelf", shelf_id, uid)
            floor = db.get("floor", changes.get("floor_id", shelf["floor_id"]), uid)
            if floor["store_id"] != shelf["store_id"]:
                raise HTTPException(422, "Floor belongs to a different store")
            if changes.get("rows") and any(
                item["row"] > changes["rows"]
                for item in db.list("item", uid, shelf["store_id"])
                if item["shelf_id"] == shelf_id
            ):
                raise HTTPException(409, "Move existing items before reducing the number of rows")
            validate_geometry({**shelf, **changes}, floor)
            return db.update("shelf", shelf_id, uid, changes)

    def inventory_event(uid: str, item: dict, product: dict, previous: int, reason: str):
        return db.event(
            uid,
            item["store_id"],
            "inventory_adjustment",
            {
                "item_id": item["id"],
                "shelf_id": item["shelf_id"],
                "product_id": product["id"],
                "product_name": product["name"],
                "price_minor": product.get("price_minor"),
                "currency": product.get("currency"),
                "delta": item["quantity"] - previous,
                "quantity": item["quantity"],
                "reason": reason,
                "owner_uid": uid,
                **provenance(),
            },
        )

    def validate_product_image(data: dict):
        if data.get("image_base64"):
            decode_image(base64_image(data["image_base64"], config), config)

    @app.post("/v1/stores/{store_id}/products", status_code=201)
    def create_product(store_id: str, payload: ProductInput, uid: Owner):
        db.get("store", store_id, uid)
        values = payload.model_dump()
        if values.get("currency"):
            check_options({"currency": values["currency"]})
        validate_product_image(values)
        return db.create("product", uid, store_id, values)

    @app.patch("/v1/products/{product_id}")
    def update_product(product_id: str, payload: ProductPatch, uid: Owner):
        values = payload.model_dump(exclude_unset=True)
        if "name" in values and values["name"] is None:
            raise HTTPException(422, "Product name cannot be cleared")
        if values.get("currency"):
            check_options({"currency": values["currency"]})
        validate_product_image(values)
        with db.transaction():
            product = db.update("product", product_id, uid, values)
            if {"name", "price_minor", "currency"} & values.keys():
                for item in db.list("item", uid, product["store_id"]):
                    if item["product_id"] == product_id:
                        inventory_event(
                            uid, item, product, item["quantity"], "product_details_correction"
                        )
            return product

    @app.get("/v1/products/lookup")
    def lookup(uid: Owner, barcode: Annotated[str, Query(min_length=1, max_length=2048)]):
        # Cache is public catalog data only. User-created product details stay owner-scoped.
        return catalog.lookup(barcode)

    def check_slot(uid: str, shelf: dict, row: int, slot: int, ignore_id: str | None = None):
        if shelf.get("rows") is not None and row > shelf["rows"]:
            raise HTTPException(422, "Row exceeds the shelf row count")
        if any(
            item["shelf_id"] == shelf["id"]
            and item["row"] == row
            and item["slot"] == slot
            and item["id"] != ignore_id
            for item in db.list("item", uid, shelf["store_id"])
        ):
            raise HTTPException(409, "The selected row and slot are already occupied")

    @app.post("/v1/shelves/{shelf_id}/items", status_code=201)
    def create_item(shelf_id: str, payload: ItemInput, uid: Owner):
        with db.transaction():
            shelf, product = db.get("shelf", shelf_id, uid), db.get("product", payload.product_id, uid)
            if product["store_id"] != shelf["store_id"]:
                raise HTTPException(422, "Product belongs to a different store")
            check_slot(uid, shelf, payload.row, payload.slot)
            item = db.create(
                "item", uid, shelf["store_id"], {**payload.model_dump(), "shelf_id": shelf_id}, shelf_id
            )
            inventory_event(uid, item, product, 0, "initial_quantity")
            return item

    @app.patch("/v1/items/{item_id}")
    def update_item(item_id: str, payload: ItemPatch, uid: Owner):
        changes = patch_data(payload)
        with db.transaction():
            item = db.get("item", item_id, uid)
            shelf = db.get("shelf", item["shelf_id"], uid)
            check_slot(
                uid, shelf, changes.get("row", item["row"]), changes.get("slot", item["slot"]), item_id
            )
            updated = db.update("item", item_id, uid, changes)
            if changes:
                inventory_event(
                    uid,
                    updated,
                    db.get("product", item["product_id"], uid),
                    item["quantity"],
                    "user_correction",
                )
            return updated

    @app.post("/v1/stores/{store_id}/scan")
    async def scan(store_id: str, uid: Owner, file: UploadFile = File(...)):
        db.get("store", store_id, uid)
        try:
            raw = await file.read(config.data["limits"]["max_image_bytes"] + 1)
        finally:
            await file.close()
        await run_in_threadpool(decode_image, raw, config)
        if not vision.available:
            raise HTTPException(503, vision.reason)
        async with scan_lock:
            candidates = await run_in_threadpool(vision.scan, raw)
        return {
            "candidates": candidates,
            "source": "gemini",
            "warning": "Review every candidate and enter quantities; identification may be incorrect",
        }

    @app.post("/v1/stores/{store_id}/calibrations", status_code=201)
    def calibrate(store_id: str, payload: CalibrationInput, uid: Owner):
        db.get("store", store_id, uid)
        for zone in payload.zones:
            if db.get("shelf", zone.shelf_id, uid)["store_id"] != store_id:
                raise HTTPException(422, "Calibration shelf belongs to a different store")
        if payload.frame_width * payload.frame_height > config.data["limits"]["max_image_pixels"]:
            raise HTTPException(413, "Calibration dimensions exceed image pixel limit")
        revision = len(db.list("calibration", uid, store_id)) + 1
        return db.create("calibration", uid, store_id, {**payload.model_dump(), "revision": revision})

    @app.post("/v1/stores/{store_id}/monitoring", status_code=201)
    def start_monitoring(store_id: str, payload: MonitoringInput, uid: Owner):
        store = db.get("store", store_id, uid)
        calibration = db.get("calibration", payload.calibration_id, uid)
        if calibration["store_id"] != store_id:
            raise HTTPException(422, "Calibration belongs to a different store")
        if not detector.available:
            raise HTTPException(503, detector.reason)
        with db.transaction():
            if any(session["status"] == "active" for session in db.list("monitoring", uid, store_id)):
                raise HTTPException(409, "Stop the active monitoring session before starting another")
            shelf_thresholds = {
                zone["shelf_id"]: config.thresholds(store, db.get("shelf", zone["shelf_id"], uid))
                for zone in calibration["zones"]
            }
            session = db.create(
                "monitoring",
                uid,
                store_id,
                {
                    "owner_uid": uid,
                    "calibration_id": calibration["id"],
                    "status": "active",
                    "started_at": utc_now(),
                    "ended_at": None,
                    "incomplete": False,
                    "config_revision": config.data["revision"],
                    "calibration_revision": calibration["revision"],
                    "thresholds": config.thresholds(store),
                    "shelf_thresholds": shelf_thresholds,
                    "active_tracks": [],
                    "frames": 0,
                    "bytes": 0,
                },
            )
            runtimes[session["id"]] = MonitorRuntime(session, calibration)
        return session

    @app.post("/v1/monitoring/{session_id}/stop")
    async def stop_monitoring(session_id: str, uid: Owner):
        db.get("monitoring", session_id, uid)
        runtime = runtimes.get(session_id)
        if runtime:
            async with runtime.lock:
                result = finish(uid, session_id, False)
                runtimes.pop(session_id, None)
                return result
        return finish(uid, session_id, False)

    async def process_frame(uid: str, runtime: MonitorRuntime, frame: FrameInput) -> dict:
        session = db.get("monitoring", runtime.session["id"], uid)
        if session["status"] != "active":
            raise HTTPException(409, "Monitoring session is stopped; start a fresh session")
        if frame.session_id != session["id"]:
            raise HTTPException(422, "Frame belongs to a different session")
        if frame.sequence <= runtime.sequence:
            return {
                "type": "ack",
                "sequence": frame.sequence,
                "duplicate": True,
                "processing_ms": 0,
                "tracks": [],
                "active_visits": [],
                "events": [],
                "stats": {"frames": runtime.frames},
            }
        calibration = runtime.calibration
        if frame.orientation != calibration["orientation"]:
            raise HTTPException(409, "Orientation changed; recalibrate camera zones")
        if (
            abs(frame.width / frame.height - calibration["frame_width"] / calibration["frame_height"])
            > 0.01
        ):
            raise HTTPException(409, "Camera aspect ratio changed; recalibrate camera zones")
        captured = frame.captured_at_ms / 1000
        if abs(time.time() - captured) > config.data["limits"]["max_frame_age_seconds"]:
            raise HTTPException(422, "Frame timestamp is stale or in the future; check device clock")
        if runtime.last_capture is not None and captured <= runtime.last_capture:
            raise HTTPException(422, "Frame timestamps must increase")
        if runtime.last_capture is not None and frame.captured_at_ms - round(
            runtime.last_capture * 1000
        ) < min(values["monitoring_interval_ms"] for values in session["shelf_thresholds"].values()):
            runtime.sequence = frame.sequence
            return {
                "type": "ack",
                "sequence": frame.sequence,
                "skipped": True,
                "processing_ms": 0,
                "tracks": runtime.tracker.visible(),
                "active_visits": runtime.tracker.active(),
                "events": [],
                "stats": runtime.stats(),
            }
        start = time.perf_counter()
        raw = base64_image(frame.image_base64, config)
        image = await run_in_threadpool(decode_image, raw, config)
        if image.shape[1] != frame.width or image.shape[0] != frame.height:
            raise HTTPException(422, "Frame dimensions do not match image data")
        max_dimension = max(
            values["frame_max_dimension"] for values in session["shelf_thresholds"].values()
        )
        if max(frame.width, frame.height) > max_dimension:
            scale = max_dimension / max(frame.width, frame.height)
            image = cv2.resize(
                image, (max(1, round(frame.width * scale)), max(1, round(frame.height * scale)))
            )
        minimum = min(
            threshold["minimum_confidence"] for threshold in session["shelf_thresholds"].values()
        )
        detections = await run_in_threadpool(detector.detect, image, minimum)
        events = []
        with db.transaction():
            if runtime.last_capture is not None:
                gap = captured - runtime.last_capture
                if gap <= config.data["limits"]["max_frame_age_seconds"]:
                    events.append(
                        db.event(
                            uid,
                            session["store_id"],
                            "coverage",
                            {
                                "owner_uid": uid,
                                **provenance(session, calibration),
                                "started_at": timestamp(runtime.last_capture),
                                "ended_at": timestamp(captured),
                                "shelf_ids": [zone["shelf_id"] for zone in calibration["zones"]],
                                "incomplete": False,
                            },
                        )
                    )
                else:
                    events.extend(ledger_visit(uid, runtime, runtime.tracker.finish(True)))
            events.extend(ledger_visit(uid, runtime, runtime.tracker.update(detections, captured)))
            runtime.last_capture, runtime.sequence = captured, frame.sequence
            runtime.frames += 1
            runtime.bytes += len(raw)
            active_tracks = [
                {
                    **entry,
                    "started_at": timestamp(track.entered),
                    "ended_at": timestamp(track.zone_last_seen),
                }
                for entry in runtime.tracker.active()
                if (track := runtime.tracker.tracks[entry["track_id"]])
            ]
            db.update(
                "monitoring",
                session["id"],
                uid,
                {
                    "active_tracks": active_tracks,
                    "last_captured_at": timestamp(captured),
                    "last_sequence": frame.sequence,
                    "frames": runtime.frames,
                    "bytes": runtime.bytes,
                },
            )
        elapsed = (time.perf_counter() - start) * 1000
        runtime.processing_ms.append(elapsed)
        if len(runtime.processing_ms) > 10000:
            runtime.processing_ms.pop(0)
        return {
            "type": "ack",
            "sequence": frame.sequence,
            "processing_ms": elapsed,
            "tracks": runtime.tracker.visible(),
            "active_visits": runtime.tracker.active(),
            "events": events,
            "stats": runtime.stats(),
        }

    @app.post("/v1/monitoring/{session_id}/stream/ticket")
    def stream_ticket(
        session_id: str, uid: Owner, authorization: Annotated[str | None, Header()] = None
    ):
        if not settings.cloud_mode:
            raise HTTPException(404, "Browser streams are disabled on the local server")
        session = db.get("monitoring", session_id, uid)
        if session["status"] != "active":
            raise HTTPException(409, "Start a fresh monitoring session")
        now = time.monotonic()
        for key, (_, _, expiry) in list(stream_tickets.items()):
            if expiry <= now:
                stream_tickets.pop(key, None)
        if len(stream_tickets) >= 4096:
            raise HTTPException(429, "Too many pending streams")
        ticket = secrets.token_urlsafe(32)
        stream_tickets[ticket] = (bearer(authorization), session_id, now + 30)
        return {"ticket": ticket, "expires_in": 30}

    @app.websocket("/v1/monitoring/{session_id}/stream")
    async def stream(websocket: WebSocket, session_id: str):
        runtime, uid = None, None
        try:
            protocol = None
            if websocket.headers.get("authorization"):
                token = bearer(websocket.headers.get("authorization"))
            else:
                protocols = websocket.scope.get("subprotocols", [])
                if not settings.cloud_mode or len(protocols) != 2 or protocols[0] != "shelfsight":
                    raise HTTPException(401, "Stream authentication required")
                proof = stream_tickets.pop(protocols[1], None)
                if proof is None or proof[1] != session_id or proof[2] <= time.monotonic():
                    raise HTTPException(401, "Stream ticket expired or already used")
                token, protocol = proof[0], "shelfsight"
            uid = sessions.resolve(token)["owner_uid"]
            session = db.get("monitoring", session_id, uid)
            runtime = runtimes.get(session_id)
            if not runtime or session["status"] != "active":
                raise HTTPException(409, "Start a fresh monitoring session")
            if runtime.connected:
                raise HTTPException(409, "This monitoring session already has a frame connection")
            runtime.connected = True
        except HTTPException:
            await websocket.close(code=1008, reason="Authentication or monitoring session rejected")
            return
        await websocket.accept(subprotocol=protocol)
        try:
            while True:
                # Recheck expiry/revocation during long-running connections.
                sessions.resolve(token)
                text = await asyncio.wait_for(
                    websocket.receive_text(), timeout=config.data["limits"]["max_frame_age_seconds"]
                )
                if len(text) > config.data["limits"]["max_image_bytes"] * 4 // 3 + 65536:
                    raise HTTPException(413, "Frame exceeds configured byte limit")
                try:
                    frame = FrameInput.model_validate_json(text)
                except ValidationError as exc:
                    raise HTTPException(422, "Malformed frame message") from exc
                async with runtime.lock:
                    result = await process_frame(uid, runtime, frame)
                await websocket.send_json(result)
        except (TimeoutError, WebSocketDisconnect):
            pass
        except HTTPException as exc:
            await websocket.send_json({"type": "error", "detail": exc.detail, "status": exc.status_code})
            await websocket.close(code=1008, reason="Monitoring input rejected")
        except Exception:
            await websocket.close(code=1011, reason="Frame processing failed")
        finally:
            runtime.connected = False
            async with runtime.lock:
                # Normal explicit stop has already finalized visits and remains stopped.
                try:
                    finish(uid, session_id, True)
                except HTTPException:
                    pass
                runtimes.pop(session_id, None)

    @app.get("/v1/stores/{store_id}/events")
    def events(store_id: str, uid: Owner, after: str | None = None):
        db.get("store", store_id, uid)
        values = db.events(uid, store_id)
        if after:
            index = next((i for i, event in enumerate(values) if event["id"] == after), None)
            if index is not None:
                values = values[index + 1 :]
            else:
                cutoff = parse_time(after)
                values = [event for event in values if parse_time(event["server_timestamp"]) > cutoff]
        return {"items": values}

    def default_range(start: str | None, end: str | None) -> tuple[str, str]:
        end = end or utc_now()
        start = start or (parse_time(end) - timedelta(days=1)).isoformat()
        return start, end

    @app.get("/v1/stores/{store_id}/analytics")
    def analytics(store_id: str, uid: Owner, start: str | None = None, end: str | None = None):
        start, end = default_range(start, end)
        return summarize(db, config, uid, store_id, start, end, capabilities())

    @app.get("/v1/stores/{store_id}/analytics/export")
    def export(store_id: str, uid: Owner, start: str | None = None, end: str | None = None):
        start, end = default_range(start, end)
        summary = summarize(db, config, uid, store_id, start, end, capabilities())
        return Response(
            export_csv(summary),
            media_type="text/csv; charset=utf-8",
            headers={"Content-Disposition": "attachment; filename=shelfsight-analytics.csv"},
        )

    if settings.cloud_mode and settings.web_dir.is_dir():
        app.mount("/", StaticFiles(directory=settings.web_dir, html=True), name="flutter-web")
    return app
