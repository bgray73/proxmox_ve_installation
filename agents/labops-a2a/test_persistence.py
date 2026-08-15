#!/usr/bin/env python3
"""Smoke test: tasks written via DatabaseTaskStore are readable after re-open."""

from __future__ import annotations

import asyncio
import tempfile
import unittest
from pathlib import Path

from a2a.helpers import new_task_from_user_message, new_text_message
from a2a.server.context import ServerCallContext
from a2a.server.tasks import DatabaseTaskStore
from a2a.types import Message, Part, Role, TaskState
from sqlalchemy.ext.asyncio import create_async_engine


class SqliteTaskStorePersistenceTests(unittest.TestCase):
    def test_task_survives_engine_reopen(self) -> None:
        asyncio.run(self._async_test())

    async def _async_test(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "tasks.db"
            url = f"sqlite+aiosqlite:///{db_path.resolve()}"
            ctx = ServerCallContext()

            engine1 = create_async_engine(url)
            store1 = DatabaseTaskStore(engine=engine1, create_table=True)
            await store1.initialize()

            message = Message(
                role=Role.ROLE_USER,
                parts=[Part(text="status")],
                message_id="msg-persist-1",
            )
            task = new_task_from_user_message(message)
            task.status.state = TaskState.TASK_STATE_COMPLETED
            task.status.message.CopyFrom(new_text_message("done"))

            await store1.save(task, ctx)
            task_id = task.id
            await engine1.dispose()

            engine2 = create_async_engine(url)
            store2 = DatabaseTaskStore(engine=engine2, create_table=True)
            await store2.initialize()
            loaded = await store2.get(task_id, ctx)
            await engine2.dispose()

            self.assertIsNotNone(loaded)
            assert loaded is not None
            self.assertEqual(loaded.id, task_id)
            self.assertEqual(loaded.status.state, TaskState.TASK_STATE_COMPLETED)


if __name__ == "__main__":
    unittest.main()
