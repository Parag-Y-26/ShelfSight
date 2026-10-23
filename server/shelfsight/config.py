"""Runtime configuration, separate from user-editable business configuration."""

from __future__ import annotations

import copy
import json
import math
from pathlib import Path

from pydantic import AliasChoices, Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="SHELFSIGHT_", env_file=".env", extra="ignore", populate_by_name=True
    )
    firebase_project_id: str = Field(
        default="",
        validation_alias=AliasChoices("SHELFSIGHT_FIREBASE_PROJECT_ID", "FIREBASE_PROJECT_ID"),
    )
    gemini_api_key: SecretStr = Field(
        default=SecretStr(""),
        validation_alias=AliasChoices("SHELFSIGHT_GEMINI_API_KEY", "GEMINI_API_KEY"),
    )
    gemini_thinking_level: str = ""
    gemini_max_output_tokens: int = Field(default=4096, ge=128, le=65536)
    gemini_model: str = Field(
        default="", validation_alias=AliasChoices("SHELFSIGHT_GEMINI_MODEL", "GEMINI_MODEL")
    )
    runtime_dir: Path = ROOT / "runtime"
    config_path: Path = ROOT / "config" / "defaults.json"
    host: str = "0.0.0.0"  # noqa: S104 - explicit LAN server bind; pairing remains required.
    port: int = Field(default=8443, ge=1024, le=65535)
    public_address: str = ""
    product_lookup_url: str = ""
    product_user_agent: str = "ShelfSight/0.1 (local retail research)"
    model_path: Path | None = Field(
        default=None, validation_alias=AliasChoices("SHELFSIGHT_MODEL_PATH", "DETECTOR_MODEL_PATH")
    )
    model_url: str = Field(
        default="", validation_alias=AliasChoices("SHELFSIGHT_MODEL_URL", "DETECTOR_MODEL_URL")
    )
    model_sha256: str = Field(
        default="", validation_alias=AliasChoices("SHELFSIGHT_MODEL_SHA256", "DETECTOR_MODEL_SHA256")
    )
    model_person_label: str = "person"


class BusinessConfig:
    def __init__(self, path: Path):
        self.path = path
        self.data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(self.data.get("revision"), int):
            raise ValueError("Business config requires an integer revision")
        for key in ("thresholds", "limits", "capabilities"):
            if not isinstance(self.data.get(key), dict):
                raise ValueError(f"Business config missing {key}")

    def public(self) -> dict:
        return copy.deepcopy(self.data)

    def allows(self, option: str, value: str) -> bool:
        return any(
            (item.get("id") if isinstance(item, dict) else item) == value
            for item in self.data.get(option, [])
        )

    def validate_overrides(self, overrides: dict) -> dict:
        defaults = self.data["thresholds"]
        for key, value in overrides.items():
            if key not in defaults:
                raise ValueError(f"Unsupported setting: {key}")
            if (
                isinstance(value, bool)
                or not isinstance(value, (float, int))
                or not math.isfinite(value)
            ):
                raise ValueError(f"Setting {key} must be a finite number")
            if value < 0:
                raise ValueError(f"Setting {key} cannot be negative")
            if key in {"minimum_confidence", "tracker_min_iou", "tracker_match_distance"} and value > 1:
                raise ValueError(f"Setting {key} must be between zero and one")
            if key in {"monitoring_interval_ms", "frame_max_dimension"} and value <= 0:
                raise ValueError(f"Setting {key} must be positive")
            if isinstance(defaults[key], int) and not isinstance(value, int):
                raise ValueError(f"Setting {key} must be an integer")
            if key == "frame_max_dimension" and value * value > self.data["limits"]["max_image_pixels"]:
                raise ValueError("Frame dimensions exceed image pixel limit")
        return overrides.copy()

    def thresholds(self, store: dict | None = None, shelf: dict | None = None) -> dict:
        values = self.data["thresholds"].copy()
        values.update((store or {}).get("settings", {}))
        values.update((shelf or {}).get("settings", {}))
        return values
