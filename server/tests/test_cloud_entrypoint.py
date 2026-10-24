from shelfsight import cloud
from shelfsight.config import Settings


def test_api_hosting_does_not_require_flutter_web(tmp_path, monkeypatch):
    settings = Settings(
        cloud_mode=True, supabase_url="https://test.supabase.co",
        supabase_publishable_key="sb_publishable_test", runtime_dir=tmp_path,
        web_dir=tmp_path / "no-web-build", _env_file=None,
    )
    calls = []
    application = object()
    monkeypatch.setattr(cloud, "Settings", lambda **kwargs: settings)
    monkeypatch.setattr(cloud, "create_app", lambda value: application)
    monkeypatch.setattr(cloud.uvicorn, "run", lambda app, **kwargs: calls.append((app, kwargs)))
    monkeypatch.setenv("PORT", "8080")
    cloud.main()
    assert calls[0][0] is application
    assert calls[0][1]["workers"] == 1
    assert calls[0][1]["port"] == 8080
