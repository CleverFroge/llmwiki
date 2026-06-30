"""HTTP MCP server for remote access (streamable-http transport)."""
import argparse, asyncio, logging, os, sys, uuid
from pathlib import Path
import uvicorn
from starlette.responses import PlainTextResponse
from starlette.routing import Route

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("llmwiki.http")
_LOCAL_USER_ID = os.environ.get("LLMWIKI_USER_ID", str(uuid.uuid5(uuid.NAMESPACE_DNS, "local")))
os.environ["SUPAVAULT_USER_ID"] = _LOCAL_USER_ID
import local_server

def _parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("workspace", nargs="?", default=".")
    p.add_argument("--workspace", dest="workspace_flag", default=None)
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8090)
    return p.parse_args()

def main():
    args = _parse_args()
    workspace = str(Path(args.workspace_flag or args.workspace).resolve())
    loop = asyncio.new_event_loop()
    loop.run_until_complete(local_server._init_workspace(workspace))
    loop.close()
    from mcp.server.fastmcp import FastMCP
    from mcp.server.transport_security import TransportSecuritySettings
    from tools import register
    from vaultfs import SqliteVaultFS
    mcp = FastMCP(
        name="LLM Wiki",
        instructions="You are connected to an LLM Wiki workspace. Call the `guide` tool first.",
        transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
    )
    register(mcp, lambda ctx: _LOCAL_USER_ID, lambda uid: SqliteVaultFS(uid))
    @mcp.tool(name="ping", description="Test connectivity")
    async def ping() -> str:
        return "pong"
    app = mcp.streamable_http_app()
    async def health(request):
        return PlainTextResponse("OK")
    app.router.routes.insert(0, Route("/health", health))
    logger.info("HTTP MCP ready — workspace: %s, listening :%d/mcp", workspace, args.port)
    uvicorn.run(app, host=args.host, port=args.port)

if __name__ == "__main__":
    main()
