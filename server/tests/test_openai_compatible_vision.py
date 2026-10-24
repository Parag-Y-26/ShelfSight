import json
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from shelfsight.config import ROOT, BusinessConfig, Settings
from shelfsight.vision_compatible import OpenAICompatibleVisionModel


class _Response:
    def __init__(self, payload, *, status_error=None):
        self.body = json.dumps(payload).encode()
        self.status_error = status_error

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def raise_for_status(self):
        if self.status_error:
            raise self.status_error

    def iter_bytes(self):
        yield self.body


class _Client:
    def __init__(self, **_kwargs):
        self.calls = []

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def stream(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        return _Response(
            {
                "choices": [
                    {
                        "message": {
                            "content": json.dumps(
                                {
                                    "candidates": [
                                        {
                                            "name": "Milk",
                                            "brand": "Dairy Co",
                                            "category": "Dairy",
                                            "barcode": None,
                                            "bbox": [0.1, 0.2, 0.3, 0.5],
                                        }
                                    ]
                                }
                            )
                        }
                    }
                ]
            }
        )


def _model(tmp_path, **overrides):
    values = dict(
        runtime_dir=tmp_path,
        vision_provider="nvidia-nim",
        vision_api_key="never-print-this-secret",
        vision_model="example/vision-model",
        _env_file=None,
    )
    values.update(overrides)
    settings = Settings(**values)
    return OpenAICompatibleVisionModel(settings, BusinessConfig(ROOT / "app/assets/defaults.json"))


def test_nvidia_nim_uses_openai_image_data_url_and_validated_scan_output(monkeypatch, tmp_path):
    clients = []

    def fake_client(**kwargs):
        client = _Client(**kwargs)
        clients.append(client)
        return client

    monkeypatch.setattr("shelfsight.vision_compatible.httpx.Client", fake_client)
    model = _model(tmp_path)
    result = model.scan(b"\xff\xd8shelf-image")

    assert model.available
    assert model.source == "nvidia-nim"
    assert model.base_url == "https://integrate.api.nvidia.com/v1"
    assert result == [
        {
            "name": "Milk",
            "brand": "Dairy Co",
            "category": "Dairy",
            "barcode": None,
            "bbox": [0.1, 0.2, 0.3, 0.5],
            "row": 1,
            "slot": 1,
            "confidence": None,
        }
    ]
    method, url, request = clients[0].calls[0]
    assert (method, url) == (
        "POST",
        "https://integrate.api.nvidia.com/v1/chat/completions",
    )
    assert request["headers"]["Authorization"] == "Bearer never-print-this-secret"
    image = request["json"]["messages"][1]["content"][1]
    assert image["image_url"]["url"].startswith("data:image/jpeg;base64,")


def test_generic_openai_compatible_provider_allows_custom_https_base_path(tmp_path):
    model = _model(
        tmp_path,
        vision_provider="openai-compatible",
        vision_base_url="https://example.test/openai/v1/",
    )
    assert model.available
    assert model.base_url == "https://example.test/openai/v1"


def test_provider_rejects_insecure_remote_or_cloud_local_http(tmp_path):
    local = _model(
        tmp_path,
        vision_provider="openai-compatible",
        vision_base_url="http://192.168.1.20:8000/v1",
    )
    cloud = _model(
        tmp_path,
        vision_provider="openai-compatible",
        vision_base_url="http://localhost:8000/v1",
        cloud_mode=True,
    )
    assert not local.available
    assert not cloud.available


def test_provider_failure_does_not_return_upstream_secret(monkeypatch, tmp_path):
    import httpx

    class FailedClient(_Client):
        def stream(self, *_args, **_kwargs):
            return _Response(
                {},
                status_error=httpx.HTTPStatusError(
                    "upstream failed with never-print-this-secret",
                    request=SimpleNamespace(),
                    response=SimpleNamespace(),
                ),
            )

    monkeypatch.setattr("shelfsight.vision_compatible.httpx.Client", FailedClient)
    model = _model(tmp_path)
    with pytest.raises(HTTPException) as failure:
        model.scan(b"\xff\xd8image")
    assert failure.value.status_code == 502
    assert "never-print-this-secret" not in failure.value.detail
