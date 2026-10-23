"""Cloud Run entry point; HTTPS is terminated by the Cloud Run proxy."""

import os

import uvicorn

from .api import create_app
from .config import Settings


def main():
    settings = Settings(cloud_mode=True)
    if not settings.firebase_project_id:
        raise ValueError("Cloud mode requires SHELFSIGHT_FIREBASE_PROJECT_ID")
    if not settings.web_dir.joinpath("index.html").is_file():
        raise ValueError("Build Flutter Web before starting the cloud server")
    uvicorn.run(
        create_app(settings),
        host="0.0.0.0",  # noqa: S104
        port=int(os.environ.get("PORT", "8080")),
        workers=1,
        access_log=False,
        ws_max_size=7_100_000,
        ws_max_queue=1,
    )


if __name__ == "__main__":
    main()
