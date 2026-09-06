# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "fastapi==0.116.1",
#   "uvicorn==0.35.0",
#   "httpx==0.28.1",
# ]
# ///

from __future__ import annotations

import json
import time
from collections import defaultdict, deque
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, Field

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "config" / "devices.json"
AUDIT_PATH = ROOT / "logs" / "audit.jsonl"
MCPO_BASE = "http://127.0.0.1:8001"

CONFIG = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
DEVICES: dict[str, dict[str, Any]] = CONFIG.get("devices", {})
MAX_COUNT = int(CONFIG.get("max_count", 64))
RATE_LIMIT = int(CONFIG.get("rate_limit_per_minute", 60))
REQUESTS: dict[str, deque[float]] = defaultdict(deque)

app = FastAPI(title="Auralis Industrial Guard", version="0.1.0", docs_url="/docs", redoc_url=None)


class ReadRequest(BaseModel):
    device: str = Field(min_length=1, max_length=64)
    address: int = Field(ge=0, le=999999)
    count: int = Field(ge=1, le=512)


def _audit(event: dict[str, Any]) -> None:
    AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
    event = {"ts": time.time(), **event}
    with AUDIT_PATH.open("a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")


def _rate_limit(request: Request) -> None:
    key = request.headers.get("cf-connecting-ip") or (request.client.host if request.client else "unknown")
    now = time.time()
    q = REQUESTS[key]
    while q and now - q[0] > 60:
        q.popleft()
    if len(q) >= RATE_LIMIT:
        _audit({"action": "rate_limit", "client": key, "allowed": False})
        raise HTTPException(status_code=429, detail="rate limit exceeded")
    q.append(now)


def _device(name: str) -> dict[str, Any]:
    dev = DEVICES.get(name)
    if not dev:
        raise HTTPException(status_code=404, detail="unknown device")
    return dev


def _allowed(dev: dict[str, Any], key: str, address: int, count: int) -> bool:
    if count > MAX_COUNT:
        return False
    end = address + count - 1
    for start, stop in dev.get(key, []):
        if address >= int(start) and end <= int(stop):
            return True
    return False


async def _forward(path: str, req: ReadRequest, range_key: str, request: Request) -> dict[str, Any]:
    _rate_limit(request)
    dev = _device(req.device)
    if not _allowed(dev, range_key, req.address, req.count):
        _audit({
            "action": path,
            "device": req.device,
            "address": req.address,
            "count": req.count,
            "allowed": False,
        })
        raise HTTPException(status_code=403, detail="requested range is not allowlisted")

    payload = {
        "host": dev["host"],
        "port": int(dev.get("port", 502)),
        "unit": int(dev.get("unit", 1)),
        "address": req.address,
        "count": req.count,
    }
    try:
        async with httpx.AsyncClient(timeout=12.0) as client:
            response = await client.post(f"{MCPO_BASE}/{path}", json=payload)
    except httpx.HTTPError as exc:
        _audit({"action": path, "device": req.device, "allowed": True, "ok": False, "error": str(exc)})
        raise HTTPException(status_code=502, detail="MCPO connection failed") from exc

    if response.status_code >= 400:
        _audit({
            "action": path,
            "device": req.device,
            "address": req.address,
            "count": req.count,
            "allowed": True,
            "ok": False,
            "upstream_status": response.status_code,
        })
        raise HTTPException(status_code=502, detail="upstream Modbus read failed")

    try:
        result: Any = response.json()
    except ValueError:
        result = response.text

    _audit({
        "action": path,
        "device": req.device,
        "address": req.address,
        "count": req.count,
        "allowed": True,
        "ok": True,
    })
    return {"device": req.device, "address": req.address, "count": req.count, "result": result}


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"ok": True, "mode": "read_only", "devices": sorted(DEVICES)}


@app.get("/devices")
async def devices() -> dict[str, Any]:
    safe = {
        name: {
            "register_ranges": cfg.get("register_ranges", []),
            "coil_ranges": cfg.get("coil_ranges", []),
            "discrete_input_ranges": cfg.get("discrete_input_ranges", []),
        }
        for name, cfg in DEVICES.items()
    }
    return {"devices": safe}


@app.post("/read/registers")
async def read_registers(req: ReadRequest, request: Request) -> dict[str, Any]:
    return await _forward("read_registers", req, "register_ranges", request)


@app.post("/read/coils")
async def read_coils(req: ReadRequest, request: Request) -> dict[str, Any]:
    return await _forward("read_coils", req, "coil_ranges", request)


@app.post("/read/discrete-inputs")
async def read_discrete_inputs(req: ReadRequest, request: Request) -> dict[str, Any]:
    return await _forward("read_discrete_inputs", req, "discrete_input_ranges", request)


def custom_openapi() -> dict[str, Any]:
    # Deliberately simple OpenAPI: no unions/anyOf so bounded compilers can ingest it.
    body_schema = {
        "type": "object",
        "additionalProperties": False,
        "required": ["device", "address", "count"],
        "properties": {
            "device": {"type": "string"},
            "address": {"type": "integer"},
            "count": {"type": "integer"},
        },
    }
    response_schema = {
        "type": "object",
        "properties": {
            "device": {"type": "string"},
            "address": {"type": "integer"},
            "count": {"type": "integer"},
            "result": {},
        },
    }
    paths: dict[str, Any] = {}
    for path, op_id, desc in [
        ("/read/registers", "read_registers", "Read allowlisted Modbus holding registers"),
        ("/read/coils", "read_coils", "Read allowlisted Modbus coils"),
        ("/read/discrete-inputs", "read_discrete_inputs", "Read allowlisted Modbus discrete inputs"),
    ]:
        paths[path] = {
            "post": {
                "operationId": op_id,
                "description": desc,
                "requestBody": {"required": True, "content": {"application/json": {"schema": body_schema}}},
                "responses": {"200": {"description": "Successful read", "content": {"application/json": {"schema": response_schema}}}},
            }
        }
    paths["/health"] = {"get": {"operationId": "health", "responses": {"200": {"description": "Health"}}}}
    paths["/devices"] = {"get": {"operationId": "devices", "responses": {"200": {"description": "Configured safe devices"}}}}
    return {
        "openapi": "3.1.0",
        "info": {"title": "Auralis Industrial Guard", "version": "0.1.0"},
        "paths": paths,
    }


app.openapi = custom_openapi  # type: ignore[assignment]


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8002, log_level="info")
