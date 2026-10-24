"""Runtime configuration, separate from user-editable business configuration."""

from __future__ import annotations

import copy
import json
import math
from pathlib import Path
from typing import Literal

from pydantic import AliasChoices, Field, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

ROOT = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="SHELFSIGHT_", env_file=".env", extra="ignore", populate_by_name=True
    )
    supabase_url: str = Field(
        default="",
        validation_alias=AliasChoices("SHELFSIGHT_SUPABASE_URL", "SUPABASE_URL"),
    )
    supabase_publishable_key: SecretStr = Field(
        default=SecretStr(""),
        validation_alias=AliasChoices("SHELFSIGHT_SUPABASE_PUBLISHABLE_KEY", "SUPABASE_PUBLISHABLE_KEY"),
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
    vision_provider: Literal["gemini", "nvidia-nim", "openai-compatible", "openrouter"] = Field(
        default="gemini",
        validation_alias=AliasChoices("SHELFSIGHT_VISION_PROVIDER", "VISION_PROVIDER"),
    )
    vision_api_key: SecretStr = Field(
        default=SecretStr(""),
        validation_alias=AliasChoices(
            "SHELFSIGHT_VISION_API_KEY",
            "SHELFSIGHT_OPENAI_API_KEY",
            "VISION_API_KEY",
            "OPENAI_API_KEY",
        ),
    )
    vision_base_url: str = Field(
        default="",
        validation_alias=AliasChoices(
            "SHELFSIGHT_VISION_BASE_URL",
            "SHELFSIGHT_OPENAI_BASE_URL",
            "VISION_BASE_URL",
            "OPENAI_BASE_URL",
        ),
    )
    vision_model: str = Field(
        default="",
        validation_alias=AliasChoices(
            "SHELFSIGHT_VISION_MODEL",
            "SHELFSIGHT_OPENAI_MODEL",
            "VISION_MODEL",
            "OPENAI_MODEL",
        ),
    )
    nvidia_nim_api_key: SecretStr = Field(
        default=SecretStr(""),
        validation_alias=AliasChoices("SHELFSIGHT_NVIDIA_NIM_API_KEY", "NVIDIA_NIM_API_KEY"),
    )
    nvidia_nim_model: str = Field(
        default="", validation_alias=AliasChoices("SHELFSIGHT_NVIDIA_NIM_MODEL", "NVIDIA_NIM_MODEL")
    )
    nvidia_nim_base_url: str = Field(
        default="",
        validation_alias=AliasChoices("SHELFSIGHT_NVIDIA_NIM_BASE_URL", "NVIDIA_NIM_BASE_URL"),
    )
    openrouter_api_key: SecretStr = Field(
        default=SecretStr(""),
        validation_alias=AliasChoices("SHELFSIGHT_OPENROUTER_API_KEY", "OPENROUTER_API_KEY"),
    )
    openrouter_model: str = ""
    openrouter_base_url: str = "https://openrouter.ai/api/v1"
    laya_endpoint_url: str = Field(
        default="", validation_alias=AliasChoices("SHELFSIGHT_LAYA_ENDPOINT_URL", "LAYA_ENDPOINT_URL")
    )
    laya_api_key: SecretStr = Field(
        default=SecretStr(""), validation_alias=AliasChoices("SHELFSIGHT_LAYA_API_KEY", "LAYA_API_KEY")
    )
    runtime_dir: Path = ROOT / "runtime"
    config_path: Path = ROOT / "app" / "assets" / "defaults.json"
    host: str = "0.0.0.0"  # noqa: S104 - explicit LAN server bind; pairing remains required.
    port: int = Field(default=8443, ge=1024, le=65535)
    public_address: str = ""
    cloud_mode: bool = False
    web_dir: Path = ROOT / "app" / "build" / "web"
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

    @field_validator("config_path")
    @classmethod
    def migrate_canonical_config_path(cls, value: Path) -> Path:
        legacy = ROOT / "config" / "defaults.json"
        if value.resolve() == legacy.resolve() and not legacy.exists():
            return ROOT / "app" / "assets" / "defaults.json"
        return value


class BusinessConfig:
    def __init__(self, path: Path):
        self.path = path
        self.data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(self.data.get("revision"), int):
            raise ValueError("Business config requires an integer revision")
        for key in ("settings", "setting_rules", "limits", "capabilities"):
            if not isinstance(self.data.get(key), dict):
                raise ValueError(f"Business config missing {key}")
        self.validate_overrides(self.data["settings"])

    def public(self) -> dict:
        return copy.deepcopy(self.data)

    def allows(self, option: str, value: str) -> bool:
        return any(
            (item.get("id") if isinstance(item, dict) else item) == value
            for item in self.data.get(option, [])
        )

    def normalize(self, overrides: dict) -> dict:
        result = {}
        aliases = self.data.get("legacy_settings", {})
        for key, value in overrides.items():
            alias = aliases.get(key)
            if alias:
                if "reciprocal_scale" in alias:
                    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
                        raise ValueError(f"Setting {key} must be positive")
                    value = alias["reciprocal_scale"] / value
                if alias["key"] not in overrides:
                    result[alias["key"]] = value
            else:
                result[key] = value
        return result

    def validate_overrides(self, overrides: dict) -> dict:
        values = self.normalize(overrides)
        for key, value in values.items():
            rule = self.data["setting_rules"].get(key)
            if not rule:
                raise ValueError(f"Unsupported setting: {key}")
            if rule["type"] == "string":
                if not isinstance(value, str) or value not in rule["enum"]:
                    raise ValueError(f"Invalid option for {key}")
                continue
            if (
                isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
            ):
                raise ValueError(f"Setting {key} must be a finite number")
            if rule["type"] == "integer" and value != int(value):
                raise ValueError(f"Setting {key} must be an integer")
            if (
                "min" in rule
                and value < rule["min"]
                or "max" in rule
                and value > rule["max"]
                or "exclusive_min" in rule
                and value <= rule["exclusive_min"]
            ):
                raise ValueError(f"Setting {key} is outside its allowed range")
        if values.get("frame_max_dimension", 0) ** 2 > self.data["limits"]["max_image_pixels"]:
            raise ValueError("Frame dimensions exceed image pixel limit")
        if (
            "monitoring_sample_fps" in values
            and 1 / values["monitoring_sample_fps"] >= self.data["limits"]["max_frame_age_seconds"]
        ):
            raise ValueError("Frame interval must be shorter than the frame timeout")
        return values

    def thresholds(
        self,
        store: dict | None = None,
        shelf: dict | None = None,
        device_defaults: dict | None = None,
    ) -> dict:
        values = self.data["settings"].copy()
        for overrides in (
            device_defaults or {},
            (store or {}).get("settings", {}),
            (shelf or {}).get("settings", {}),
        ):
            values.update(self.validate_overrides(overrides))
        return values
