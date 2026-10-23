"""Strict boundary schemas. Quantities, geometry, and observed confidence are never invented."""

from __future__ import annotations

from typing import Annotated, Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

Name = Annotated[str, Field(min_length=1, max_length=200)]
ID = Annotated[str, Field(min_length=1, max_length=128)]
Positive = Annotated[float, Field(gt=0, le=1_000_000)]
Orientation = Literal["portraitUp", "landscapeLeft", "portraitDown", "landscapeRight"]
SettingNumber = Annotated[int, Field(strict=True)] | Annotated[float, Field(strict=True)]


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False, str_strip_whitespace=True)


class PairInput(Input):
    pairing_secret: Annotated[str, Field(min_length=20, max_length=256)]
    device_name: Name


class CloudSessionInput(Input):
    device_name: Name


class FloorInput(Input):
    name: Name
    width: Positive
    length: Positive


class FloorPatch(Input):
    name: Name | None = None
    width: Positive | None = None
    length: Positive | None = None


class StoreInput(Input):
    name: Name
    type_id: ID
    goal_id: ID
    currency: Annotated[str, Field(min_length=3, max_length=3)]
    unit: Annotated[str, Field(max_length=16)]
    timezone: Annotated[str, Field(max_length=100)]
    shelf_count: Annotated[int, Field(strict=True, ge=0, le=1000)]
    floor: FloorInput

    @field_validator("timezone")
    @classmethod
    def valid_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            raise ValueError("Unknown IANA timezone") from exc
        return value


class StorePatch(Input):
    name: Name | None = None
    currency: Annotated[str, Field(min_length=3, max_length=3)] | None = None
    unit: Annotated[str, Field(max_length=16)] | None = None
    settings: dict[str, SettingNumber] | None = None


class ShelfInput(Input):
    name: Name
    floor_id: ID


class ShelfPatch(Input):
    name: Name | None = None
    floor_id: ID | None = None
    shape: ID | None = None
    x: Annotated[float, Field(ge=0)] | None = None
    y: Annotated[float, Field(ge=0)] | None = None
    width: Positive | None = None
    length: Positive | None = None
    rotation: Literal[0, 90, 180, 270] | None = None
    rows: Annotated[int, Field(strict=True, ge=1, le=1000)] | None = None
    settings: dict[str, SettingNumber] | None = None


class ProductInput(Input):
    name: Name
    barcode: Annotated[str, Field(max_length=2048)] | None = None
    brand: Annotated[str, Field(max_length=300)] | None = None
    category: Annotated[str, Field(max_length=500)] | None = None
    net_weight: Annotated[str, Field(max_length=100)] | None = None
    price_minor: Annotated[int, Field(strict=True, ge=0, le=10**12)] | None = None
    currency: Annotated[str, Field(min_length=3, max_length=3)] | None = None
    is_veg: bool | None = None
    ingredients: Annotated[str, Field(max_length=20_000)] | None = None
    allergens: Annotated[str, Field(max_length=10_000)] | None = None
    nutrition: dict[str, str | float | int | None] | None = None
    manufacturer: Annotated[str, Field(max_length=1000)] | None = None
    shelf_life: Annotated[str, Field(max_length=300)] | None = None
    image_base64: Annotated[str, Field(max_length=7_000_000)] | None = None
    source: Annotated[str, Field(max_length=100)] | None = None


class ProductPatch(ProductInput):
    name: Name | None = None


class ItemInput(Input):
    product_id: ID
    row: Annotated[int, Field(strict=True, ge=1, le=1000)]
    slot: Annotated[int, Field(strict=True, ge=1, le=10000)]
    quantity: Annotated[int, Field(strict=True, ge=0, le=10**9)]


class ItemPatch(Input):
    row: Annotated[int, Field(strict=True, ge=1, le=1000)] | None = None
    slot: Annotated[int, Field(strict=True, ge=1, le=10000)] | None = None
    quantity: Annotated[int, Field(strict=True, ge=0, le=10**9)] | None = None


class Zone(Input):
    shelf_id: ID
    x: Annotated[float, Field(ge=0, le=1)]
    y: Annotated[float, Field(ge=0, le=1)]
    width: Annotated[float, Field(gt=0, le=1)]
    height: Annotated[float, Field(gt=0, le=1)]

    @model_validator(mode="after")
    def inside_image(self):
        if self.x + self.width > 1.00000001 or self.y + self.height > 1.00000001:
            raise ValueError("Zone must fit within normalized image coordinates")
        return self


class CalibrationInput(Input):
    orientation: Orientation
    frame_width: Annotated[int, Field(strict=True, gt=0, le=16384)]
    frame_height: Annotated[int, Field(strict=True, gt=0, le=16384)]
    zones: Annotated[list[Zone], Field(min_length=1, max_length=1000)]

    @model_validator(mode="after")
    def no_overlap(self):
        if len({zone.shelf_id for zone in self.zones}) != len(self.zones):
            raise ValueError("A shelf can have only one camera zone per calibration")
        for i, a in enumerate(self.zones):
            for b in self.zones[i + 1 :]:
                if (
                    a.x < b.x + b.width
                    and b.x < a.x + a.width
                    and a.y < b.y + b.height
                    and b.y < a.y + a.height
                ):
                    raise ValueError("Camera interaction zones cannot overlap")
        return self


class MonitoringInput(Input):
    calibration_id: ID


class FrameInput(Input):
    type: Literal["frame"]
    session_id: ID
    sequence: Annotated[int, Field(strict=True, ge=0)]
    captured_at_ms: Annotated[int, Field(strict=True, gt=0)]
    orientation: Orientation
    width: Annotated[int, Field(strict=True, gt=0, le=16384)]
    height: Annotated[int, Field(strict=True, gt=0, le=16384)]
    image_base64: Annotated[str, Field(min_length=4, max_length=7_000_000)]


class Candidate(Input):
    name: Name
    brand: Annotated[str, Field(max_length=300)] | None = None
    category: Annotated[str, Field(max_length=500)] | None = None
    barcode: Annotated[str, Field(max_length=2048)] | None = None
    bbox: Annotated[list[Annotated[float, Field(ge=0, le=1)]], Field(min_length=4, max_length=4)]

    @model_validator(mode="after")
    def valid_box(self):
        if self.bbox[0] >= self.bbox[2] or self.bbox[1] >= self.bbox[3]:
            raise ValueError("Bounding box must have positive area")
        return self


class ScanOutput(Input):
    candidates: Annotated[list[Candidate], Field(max_length=250)]
