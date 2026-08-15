"""LabOps status agent executor for the A2A Python SDK."""

from __future__ import annotations

import re
from datetime import datetime, timezone

from a2a.helpers import (
    get_message_text,
    new_task_from_user_message,
    new_text_message,
    new_text_part,
)
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import TaskUpdater
from a2a.types import TaskState


class LabOpsStatusAgent:
    """Minimal deterministic LabOps helper (no external APIs)."""

    _DEVICES = {
        "pve01": {"role": "proxmox-ve", "status": "online", "latency_ms": 2.1},
        "pve02": {"role": "proxmox-ve", "status": "online", "latency_ms": 2.4},
        "pve03": {"role": "proxmox-ve", "status": "degraded", "latency_ms": 48.0},
        "pve04": {"role": "proxmox-ve", "status": "online", "latency_ms": 1.9},
        "pbs01": {"role": "proxmox-backup", "status": "online", "latency_ms": 3.2},
    }

    async def invoke(self, user_request: str) -> str:
        text = (user_request or "").strip().lower()
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

        if not text:
            return "No text input provided. Try: status, list devices, or status pve03."

        if "help" in text:
            return (
                "LabOps Status Agent commands:\n"
                "- status | health \u2014 fleet summary\n"
                "- list devices \u2014 inventory\n"
                "- status <name> \u2014 single device (e.g. status pve03)\n"
                "- help \u2014 this message"
            )

        match = re.search(r"\b(pve0[1-4]|pbs01)\b", text)
        if match and ("status" in text or "check" in text or "health" in text):
            name = match.group(1)
            d = self._DEVICES[name]
            return (
                f"[{now}] {name} ({d['role']}): {d['status']}, "
                f"latency={d['latency_ms']}ms"
            )

        if "list" in text and "device" in text:
            lines = [f"[{now}] LabOps inventory:"]
            for name, d in self._DEVICES.items():
                lines.append(f"- {name}: {d['role']} / {d['status']}")
            return "\n".join(lines)

        if any(k in text for k in ("status", "health", "fleet", "summary")):
            online = sum(1 for d in self._DEVICES.values() if d["status"] == "online")
            degraded = sum(1 for d in self._DEVICES.values() if d["status"] == "degraded")
            offline = sum(1 for d in self._DEVICES.values() if d["status"] == "offline")
            return (
                f"[{now}] LabOps fleet: {online} online, {degraded} degraded, "
                f"{offline} offline (total {len(self._DEVICES)})"
            )

        return (
            f"[{now}] Acknowledged: {user_request!r}. "
            "Say 'help' for commands, or 'status' for a fleet summary."
        )


class LabOpsAgentExecutor(AgentExecutor):
    """A2A AgentExecutor wrapping LabOpsStatusAgent."""

    def __init__(self) -> None:
        self.agent = LabOpsStatusAgent()

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        if context.current_task:
            task = context.current_task
        else:
            task = new_task_from_user_message(context.message)
            await event_queue.enqueue_event(task)

        updater = TaskUpdater(
            event_queue=event_queue,
            task_id=task.id,
            context_id=task.context_id,
        )
        await updater.update_status(
            state=TaskState.TASK_STATE_WORKING,
            message=new_text_message("Processing LabOps request..."),
        )

        query = get_message_text(context.message) if context.message else ""
        result = await self.agent.invoke(user_request=query)

        await updater.add_artifact(
            parts=[new_text_part(text=result, media_type="text/plain")]
        )
        await updater.update_status(
            state=TaskState.TASK_STATE_COMPLETED,
            message=new_text_message("Request completed."),
        )

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        raise NotImplementedError("Cancel is not supported for this demo agent.")
