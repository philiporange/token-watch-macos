"""Run the AIPace FastAPI service with its environment-derived settings."""

import uvicorn

from aipace_server.config import settings


if __name__ == "__main__":
    uvicorn.run(
        "aipace_server.main:app",
        host=settings.host,
        port=settings.port,
        reload=False,
    )
