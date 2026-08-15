#!/usr/bin/env python3
"""Unit tests for LabOps agent logic (no network)."""

from __future__ import annotations

import asyncio
import unittest

from agent_executor import LabOpsStatusAgent


class LabOpsStatusAgentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.agent = LabOpsStatusAgent()

    def _invoke(self, text: str) -> str:
        return asyncio.run(self.agent.invoke(text))

    def test_help(self) -> None:
        out = self._invoke("help")
        self.assertIn("status", out.lower())
        self.assertIn("list devices", out.lower())

    def test_fleet_status(self) -> None:
        out = self._invoke("status")
        self.assertIn("online", out)
        self.assertIn("degraded", out)

    def test_list_devices(self) -> None:
        out = self._invoke("list devices")
        self.assertIn("pve01", out)
        self.assertIn("pbs01", out)

    def test_single_device(self) -> None:
        out = self._invoke("status pve03")
        self.assertIn("pve03", out)
        self.assertIn("degraded", out)

    def test_empty(self) -> None:
        out = self._invoke("")
        self.assertIn("No text input", out)


if __name__ == "__main__":
    unittest.main()
