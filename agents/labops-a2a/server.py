#!/usr/bin/env python3
"""A2A JSON-RPC server for the LabOps status agent with optional SQLite persistence."""

from __future__ import annotations

import argparse
import asyncio
from pathlib import Path

import uvicorn
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.routes import create_agent_card_routes, create_jsonrpc_routes
from a2a.server.tasks import (
    DatabasePushNotificationConfigStore,
    DatabaseTaskStore,
    InMemoryPushNotificationConfigStore,
    InMemoryTaskStore,
)
from a2a.types import AgentCapabilities, AgentCard, AgentInterface, AgentSkill
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine
from starlette.applications import Starlette

from agent_executor import LabOpsAgentExecutor


def build_agent_card(host: str, port: int) -> AgentCard:
    base = f"http://{host}:{port}"
    skill = AgentSkill(
        id="labops_status",
        name="LabOps Status",
        description=(
            "Reports simulated Proxmox/LabOps device health. "
            "Commands: status, list devices, status <device>, help."
        ),
        input_modes=["text/plain"],
        output_modes=["text/plain"],
        tags=["labops", "proxmox", "monitoring", "status"],
        examples=["status", "list devices", "status pve03", "help"],
    )
    return AgentCard(
        name="LabOps Status Agent",
        description=(
            "Demo A2A agent for LabOps/Proxmox-style fleet status. "
            "Uses in-memory mock inventory \u2014 not connected to a live cluster. "
            "Task history can be persisted to SQLite."
        ),
        version="0.2.0",
        default_input_modes=["text/plain"],
        default_output_modes=["text/plain"],
        capabilities=AgentCapabilities(streaming=True),
        supported_interfaces=[
            AgentInterface(
                protocol_binding="JSONRPC",
                url=base,
                protocol_version="1.0",
            )
        ],
        skills=[skill],
    )


def create_sqlite_engine(db_path: Path) -> AsyncEngine:
    """Create an async SQLAlchemy engine for SQLite."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    url = f"sqlite+aiosqlite:///{db_path.resolve()}"
    return create_async_engine(url, echo=False)


async def init_stores(
    engine: AsyncEngine | None,
) -> tuple[object, object]:
    """Build and initialize task + push-notification stores."""
    if engine is None:
        return InMemoryTaskStore(), InMemoryPushNotificationConfigStore()

    task_store = DatabaseTaskStore(engine=engine, create_table=True)
    push_store = DatabasePushNotificationConfigStore(engine=engine, create_table=True)
    await task_store.initialize()
    await push_store.initialize()
    return task_store, push_store


def create_app(
    host: str,
    port: int,
    *,
    task_store: object,
    push_store: object,
) -> Starlette:
    card = build_agent_card(host, port)
    handler = DefaultRequestHandler(
        agent_executor=LabOpsAgentExecutor(),
        task_store=task_store,  # type: ignore[arg-type]
        agent_card=card,
        push_config_store=push_store,  # type: ignore[arg-type]
    )
    routes = []
    routes.extend(create_agent_card_routes(card))
    routes.extend(create_jsonrpc_routes(handler, "/"))
    return Starlette(routes=routes)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run LabOps A2A agent server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9999)
    parser.add_argument(
        "--db",
        default="data/labops_a2a.db",
        help="SQLite database path (default: data/labops_a2a.db). "
        "Use 'memory' for InMemoryTaskStore (no persistence).",
    )
    args = parser.parse_args()

    engine: AsyncEngine | None
    if args.db.strip().lower() in {"memory", "none", "inmemory", ":memory:"}:
        engine = None
        db_label = "in-memory (no persistence)"
    else:
        engine = create_sqlite_engine(Path(args.db))
        db_label = str(Path(args.db).resolve())

    task_store, push_store = asyncio.run(init_stores(engine))
    app = create_app(args.host, args.port, task_store=task_store, push_store=push_store)

    print(f"LabOps A2A agent listening on http://{args.host}:{args.port}")
    print(f"Agent Card: http://{args.host}:{args.port}/.well-known/agent-card.json")
    print(f"Task store: {db_label}")
    uvicorn.run(app, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
