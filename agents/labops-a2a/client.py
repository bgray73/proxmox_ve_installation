#!/usr/bin/env python3
"""A2A client for the LabOps status agent."""

from __future__ import annotations

import argparse
import asyncio
import sys
from uuid import uuid4

import httpx
from a2a.client import A2ACardResolver, ClientConfig, ClientFactory
from a2a.types import Message, Part, Role, SendMessageRequest


def _extract_texts(item: object) -> list[str]:
    """Best-effort text extraction from protobuf-like stream items."""
    texts: list[str] = []
    s = str(item)
    if "artifact_update" in s or "parts {" in s:
        import re

        texts.extend(re.findall(r'text:\s*"((?:[^"\\]|\\.)*)"', s))
    return texts


async def run(base_url: str, text: str) -> int:
    async with httpx.AsyncClient(timeout=30.0) as httpx_client:
        resolver = A2ACardResolver(httpx_client=httpx_client, base_url=base_url)
        card = await resolver.get_agent_card()
        print(f"Connected to: {card.name} v{card.version}")
        print(f"Description: {card.description}")
        if card.skills:
            print("Skills:")
            for skill in card.skills:
                print(f"  - {skill.id}: {skill.name}")

        factory = ClientFactory(config=ClientConfig(streaming=True))
        client = factory.create(card)

        message = Message(
            role=Role.ROLE_USER,
            parts=[Part(text=text)],
            message_id=uuid4().hex,
        )
        request = SendMessageRequest(message=message)

        print(f"\n>>> {text}\n")
        result = client.send_message(request)
        artifact_texts: list[str] = []
        if hasattr(result, "__aiter__"):
            async for item in result:
                for t in _extract_texts(item):
                    if t and t not in (
                        "Processing LabOps request...",
                        "Request completed.",
                    ):
                        artifact_texts.append(t)
        else:
            if asyncio.iscoroutine(result):
                result = await result
            print(result)
            return 0

        if artifact_texts:
            print(artifact_texts[-1].encode("utf-8").decode("unicode_escape"))
        else:
            print("(no artifact text decoded; raw stream consumed successfully)")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description="Call LabOps A2A agent")
    parser.add_argument(
        "--url",
        default="http://127.0.0.1:9999",
        help="Base URL of the A2A agent",
    )
    parser.add_argument(
        "message",
        nargs="?",
        default="status",
        help="Message text to send (default: status)",
    )
    args = parser.parse_args()
    try:
        raise SystemExit(asyncio.run(run(args.url.rstrip("/"), args.message)))
    except httpx.ConnectError:
        print(
            f"Could not connect to {args.url}. Start the server with: python server.py",
            file=sys.stderr,
        )
        raise SystemExit(1)


if __name__ == "__main__":
    main()
