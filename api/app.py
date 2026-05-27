"""Set up logging before importing anything else"""

import sentry_sdk

from api.constants import DEPLOYMENT_MODE, ENABLE_TELEMETRY, SENTRY_DSN
from api.logging_config import ENVIRONMENT, setup_logging

# Set up logging and get the listener for cleanup
setup_logging()


if SENTRY_DSN and (
    DEPLOYMENT_MODE != "oss" or (DEPLOYMENT_MODE == "oss" and ENABLE_TELEMETRY)
):
    sentry_sdk.init(
        dsn=SENTRY_DSN,
        send_default_pii=True,
        environment=ENVIRONMENT,
    )
    print(f"Sentry initialized in environment: {ENVIRONMENT}")


from contextlib import asynccontextmanager

from fastapi import APIRouter, FastAPI, WebSocket
from fastapi.middleware.cors import CORSMiddleware
from loguru import logger

from api.constants import REDIS_URL
from api.mcp_server import mcp
from api.routes.main import router as main_router
from api.services.pipecat.tracing_config import (
    handle_langfuse_sync,
    load_all_org_langfuse_credentials,
)
from api.services.worker_sync.manager import (
    WorkerSyncManager,
    set_worker_sync_manager,
)
from api.services.worker_sync.protocol import WorkerSyncEventType
from api.tasks.arq import get_arq_redis

API_PREFIX = "/api/v1"

mcp_app = mcp.http_app(path="/", stateless_http=True)


@asynccontextmanager
async def lifespan(app: FastAPI):
    async with mcp_app.lifespan(app):
        # warmup arq pool
        await get_arq_redis()

        # Pre-register all org-specific Langfuse exporters so they're ready
        # before any pipeline runs, without per-call DB lookups.
        await load_all_org_langfuse_credentials()

        # Start cross-worker sync manager so config changes propagate to all workers
        sync_manager = WorkerSyncManager(REDIS_URL)
        sync_manager.register(
            WorkerSyncEventType.LANGFUSE_CREDENTIALS, handle_langfuse_sync
        )
        await sync_manager.start()
        set_worker_sync_manager(sync_manager)

        yield  # Run app

        # Shutdown sequence - this runs when FastAPI is shutting down
        logger.info("Starting graceful shutdown...")
        await sync_manager.stop()


app = FastAPI(
    title="Dograh API",
    description="API for the Dograh app",
    version="1.0.0",
    openapi_url=f"{API_PREFIX}/openapi.json",
    lifespan=lifespan,
    servers=[
        {"url": "https://app.dograh.com", "description": "Production"},
        {"url": "http://localhost:8000", "description": "Local development"},
    ],
)


# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Allows all origins
    allow_credentials=True,
    allow_methods=["*"],  # Allows all methods
    allow_headers=["*"],  # Allows all headers
)

api_router = APIRouter()

# include subrouters here
api_router.include_router(main_router)

# main router with api prefix
app.include_router(api_router, prefix=API_PREFIX)

# Mount the MCP server — agents reach it at /api/v1/mcp over Streamable HTTP,
# authenticating with the same X-API-Key header used by the REST API.
# Mounted under /api/v1 so existing reverse-proxy rules (nginx etc.) route it
# without any extra configuration.
app.mount(f"{API_PREFIX}/mcp", mcp_app)


@app.websocket("/{path:path}")
async def root_websocket_catchall(websocket: WebSocket, path: str):
    """
    Catch-all root level WebSocket route to intercept Asterisk chan_websocket client connections.
    
    Asterisk's websocket client strips the URL path component (like /api/v1/telephony/ws/ari)
    and sends the upgrade request to the root path containing parameters, for example:
    /v(workflow_id=4319,user_id=1576,workflow_run_id=526174)d(both)
    
    We parse the path (and fallback query params) using regex to extract workflow_id, user_id, 
    and workflow_run_id, accept the WebSocket with subprotocol="media", and delegate 
    handling to _handle_telephony_websocket.
    """
    import re
    logger.info(f"Incoming root WebSocket connection: path='{path}', query_params='{websocket.query_params}'")
    
    # Try to extract parameters using regex from the path and query parameters
    search_string = f"{path}?{websocket.query_params}"
    
    workflow_id_match = re.search(r"workflow_id=(\d+)", search_string)
    user_id_match = re.search(r"user_id=(\d+)", search_string)
    workflow_run_id_match = re.search(r"workflow_run_id=(\d+)", search_string)
    
    if not (workflow_id_match and user_id_match and workflow_run_id_match):
        logger.error(f"Root WebSocket connection rejected: missing parameters in search string '{search_string}'")
        await websocket.close(code=4400, reason="Missing required routing parameters")
        return
        
    workflow_id = int(workflow_id_match.group(1))
    user_id = int(user_id_match.group(1))
    workflow_run_id = int(workflow_run_id_match.group(1))
    
    logger.info(
        f"Parsed routing parameters: workflow_id={workflow_id}, user_id={user_id}, workflow_run_id={workflow_run_id}. "
        f"Accepting connection with 'media' subprotocol..."
    )
    
    # Asterisk chan_websocket requires the 'media' subprotocol echoed back
    await websocket.accept(subprotocol="media")
    
    # Import inside handler to avoid circular dependencies
    from api.routes.telephony import _handle_telephony_websocket
    
    await _handle_telephony_websocket(
        websocket, workflow_id, user_id, workflow_run_id
    )

