# LabOps A2A Agent (Python SDK)

Minimal **Agent2Agent (A2A) protocol** server and client using the official [`a2a-sdk`](https://github.com/a2aproject/a2a-python) (spec 1.0).

This agent exposes a simulated LabOps / Proxmox fleet status skill over JSON-RPC. It is a learning/demo implementation — not connected to a live cluster.

Optional companion under `agents/labops-a2a/` in `proxmox_ve_installation`. **Not required** for PVE/PBS install.

## Persistence (SQLite)

```bash
python server.py --db data/labops_a2a.db
```

Use `--db memory` for in-memory stores.

## Docker

```bash
docker build -t labops-a2a-agent .
docker run --rm -p 9999:9999 -v labops-a2a-data:/data labops-a2a-agent
docker compose up --build -d
```

Agent Card: `http://127.0.0.1:9999/.well-known/agent-card.json`

## Requirements

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

## Run

```bash
python server.py --host 127.0.0.1 --port 9999
python client.py status
python client.py "list devices"
python -m unittest test_agent.py test_persistence.py -v
```

## Protocol notes

- Binding: JSON-RPC over HTTP
- Discovery: `GET /.well-known/agent-card.json`
- Task lifecycle: WORKING → artifact → COMPLETED
