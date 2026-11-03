from fastapi import FastAPI
from fastapi.openapi.utils import get_openapi
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from contextlib import asynccontextmanager
from loguru import logger
import sys
import os

from app.database import connect_to_mongo, close_mongo_connection
from app.routers import equipment
from app.routers import stream

logger.remove()
logger.add(sys.stdout, colorize=True, format="<green>{time:YYYY-MM-DD HH:mm:ss}</green> | <level>{level: <8}</level> | <cyan>{name}</cyan>:<cyan>{function}</cyan> - <level>{message}</level>")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    logger.info("🚀 Starting Industrial MVP backend...")
    await connect_to_mongo()
    yield
    # Shutdown
    logger.info("🛑 Shutting down...")
    await close_mongo_connection()


app = FastAPI(
    title="Industrial MVP API",
    description="MVP version of Industrial voice bot with RAG",
    version="0.1.0",
    lifespan=lifespan,
)


allowed_origins_env = os.getenv("ALLOWED_ORIGINS", "")
if allowed_origins_env:
    origins = [origin.strip() for origin in allowed_origins_env.split(",")]
else:
    origins = [
        "http://localhost:5173",
        "http://localhost:3000",
        "http://127.0.0.1:5173",
        "http://127.0.0.1:3000",
        "http://frontend:80",  # Docker internal network
        "http://proj3-frontend:80",  # Docker container name
        "http://proj3-frontend-prod:80",  # Production container name
    ]

if os.getenv("ENVIRONMENT") == "production":
    logger.info(f"CORS configured for production with origins: {origins}")
else:
    # In development, allow all origins
    origins = ["*"]
    logger.info("CORS configured for development (allowing all origins)")

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True if origins != ["*"] else False,
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["*"],
)


app.include_router(equipment.router, prefix="/api/v1/equipment", tags=["Equipment"])
app.include_router(stream.router, prefix="/api/v1/stream", tags=["Stream"])


def _mark_binary_fields(node):
    """Add `format: binary` to file schemas so Swagger UI renders a file picker.

    With OpenAPI 3.1, FastAPI describes UploadFile as
    {"type": "string", "contentMediaType": "application/octet-stream"},
    which Swagger UI shows as a plain text input (especially for List[UploadFile]).
    """
    if isinstance(node, dict):
        if node.get("type") == "string" and node.get("contentMediaType") == "application/octet-stream":
            node["format"] = "binary"
        for value in node.values():
            _mark_binary_fields(value)
    elif isinstance(node, list):
        for item in node:
            _mark_binary_fields(item)


def custom_openapi():
    if app.openapi_schema:
        return app.openapi_schema
    schema = get_openapi(
        title=app.title,
        version=app.version,
        description=app.description,
        routes=app.routes,
    )
    _mark_binary_fields(schema)
    app.openapi_schema = schema
    return schema


app.openapi = custom_openapi

@app.get("/")
def read_root():
    return {"message": "Industrial MVP API is running", "version": "0.1.0"}


@app.get("/health")
def health_check():
    return {"status": "healthy"}



if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8001, reload=True)