"""Shared JSON schema validation and bounded provider HTTP transport."""

from __future__ import annotations

import json
import math
import time

import httpx


def validate_json(schema: dict, value):
    kind = schema.get("type")
    types = kind if isinstance(kind, list) else [kind]
    valid = {
        "null": value is None,
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "boolean": isinstance(value, bool),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value),
    }
    if not any(valid.get(item, False) for item in types):
        raise ValueError("AI output has an invalid type")
    if "enum" in schema and value not in schema["enum"]:
        raise ValueError("AI output has an invalid option")
    if value is None:
        return value
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        if not set(schema.get("required", [])) <= value.keys():
            raise ValueError("AI output is missing required fields")
        if schema.get("additionalProperties") is False and value.keys() - properties.keys():
            raise ValueError("AI output has unsupported fields")
        for key, item in value.items():
            if key in properties:
                validate_json(properties[key], item)
    elif isinstance(value, list):
        if not schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", math.inf):
            raise ValueError("AI output array exceeds its bounds")
        for item in value:
            validate_json(schema["items"], item)
    elif isinstance(value, str):
        if not schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", math.inf):
            raise ValueError("AI output text exceeds its bounds")
    elif not isinstance(value, bool):
        if not schema.get("minimum", -math.inf) <= value <= schema.get("maximum", math.inf):
            raise ValueError("AI output number exceeds its bounds")
    return value


def gemini_schema(schema: dict) -> dict:
    kinds = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
    result = {"type": next(kind for kind in kinds if kind != "null").upper()}
    if "null" in kinds:
        result["nullable"] = True
    for key in ("required", "minItems", "maxItems", "minimum", "maximum"):
        if key in schema:
            result[key] = schema[key]
    if "enum" in schema and all(isinstance(item, str) for item in schema["enum"]):
        result["enum"] = schema["enum"]
    if "properties" in schema:
        result["properties"] = {key: gemini_schema(value) for key, value in schema["properties"].items()}
    if "items" in schema:
        result["items"] = gemini_schema(schema["items"])
    return result


def json_text(value: str) -> dict:
    value = value.strip()
    if value.startswith("```") and value.endswith("```"):
        value = value[3:-3].strip()
        if value.startswith("json"):
            value = value[4:].lstrip()
    return json.loads(value)


def bounded_json_post(
    url: str, headers: dict, payload: dict, timeout: float, maximum: int = 1_000_000
) -> dict:
    started = time.monotonic()
    with httpx.Client(timeout=timeout, follow_redirects=False) as client:
        with client.stream("POST", url, headers=headers, json=payload) as response:
            response.raise_for_status()
            content = bytearray()
            for chunk in response.iter_bytes():
                content.extend(chunk)
                if len(content) > maximum or time.monotonic() - started > timeout:
                    raise ValueError("Provider response exceeded its bounds")
    result = json.loads(content)
    if not isinstance(result, dict):
        raise ValueError("Provider returned an invalid envelope")
    return result
