from __future__ import annotations
import asyncio
import json
import logging
import time
import uuid
from typing import Any, Dict, Optional

import aiohttp
from aiohttp_socks import ProxyConnector, ProxyType

from config import cfg

logger = logging.getLogger(__name__)

GB = 1024 ** 3
DAY_MS = 86_400_000


class PanelError(Exception):
    pass


class PanelClient:
    def __init__(self) -> None:
        self._session: Optional[aiohttp.ClientSession] = None
        self._p = cfg.panel_path

    async def _sess(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            if cfg.proxy_enabled:
                connector = ProxyConnector(
                    proxy_type=ProxyType.SOCKS5,
                    host=cfg.proxy_host,
                    port=int(cfg.proxy_port),
                    rdns=True,
                    ssl=False,
                    limit=10,
                    ttl_dns_cache=300,
                )
            else:
                connector = aiohttp.TCPConnector(limit=10, ttl_dns_cache=300)
            self._session = aiohttp.ClientSession(
                base_url=cfg.panel_url,
                headers={
                    "Authorization": f"Bearer {cfg.panel_api_token}",
                    "Content-Type": "application/json",
                },
                connector=connector,
                connector_owner=True,
                timeout=aiohttp.ClientTimeout(total=30, connect=10),
            )
        return self._session

    async def _req(self, method: str, path: str, **kwargs: Any) -> Any:
        sess = await self._sess()
        for attempt in range(3):
            try:
                async with getattr(sess, method)(path, **kwargs) as resp:
                    text = await resp.text()
                    if resp.status >= 400:
                        raise PanelError(f"{method.upper()} {path} -> {resp.status}: {text[:300]}")
                    try:
                        data = json.loads(text)
                    except json.JSONDecodeError:
                        return text
                    if isinstance(data, dict) and data.get("success") is False:
                        raise PanelError(f"Panel error: {data.get('msg', text[:200])}")
                    return data
            except PanelError:
                raise
            except Exception as e:
                if attempt == 2:
                    raise PanelError(f"Request failed: {e}") from e
                await asyncio.sleep(1)

    async def close(self) -> None:
        if self._session and not self._session.closed:
            await self._session.close()

    def _default_inbound_ids(self) -> list:
        return [i_id for i_id, _remark, _flow in cfg.inbounds] if cfg.inbounds else [cfg.inbound_id]

    def _default_flow(self) -> str:
        return next((f for _id, _remark, f in cfg.inbounds if f), "") if cfg.inbounds else ""

    async def add_client(self, email: str, sub_id: str, traffic_bytes: int, expire_ms: int,
                         inbound_ids=None, flow=None) -> None:
        if inbound_ids is None:
            inbound_ids = self._default_inbound_ids()
        if flow is None:
            flow = self._default_flow()
        payload = {
            "client": {
                "email": email,
                "subId": sub_id,
                "flow": flow,
                "totalGB": traffic_bytes,
                "expiryTime": expire_ms,
                "tgId": 0,
                "limitIp": 0,
                "enable": True,
            },
            "inboundIds": [int(i) for i in inbound_ids],
        }
        await self._req("post", f"{self._p}/panel/api/clients/add", json=payload)

    async def update_client(
        self,
        email: str,
        sub_id: str,
        traffic_bytes: int,
        expire_ms: int,
        client_id: Optional[str] = None,
        flow: Optional[str] = None,
    ) -> None:
        if flow is None:
            flow = self._default_flow()
        payload = {
            "email": email,
            "subId": sub_id,
            "flow": flow,
            "totalGB": traffic_bytes,
            "expiryTime": expire_ms,
            "tgId": 0,
            "limitIp": 0,
            "enable": True,
        }
        if client_id:
            payload["id"] = str(client_id)
        await self._req("post", f"{self._p}/panel/api/clients/update/{email}", json=payload)

    async def delete_client(self, email: str) -> None:
        await self._req("post", f"{self._p}/panel/api/clients/del/{email}")

    async def get_client(self, email: str) -> Optional[Dict]:
        data = await self._req("get", f"{self._p}/panel/api/clients/get/{email}")
        obj = data.get("obj", {})
        client = obj.get("client", {})
        return {
            "id": client.get("id", ""),
            "email": client.get("email", email),
            "subId": client.get("subId", ""),
            "flow": client.get("flow", ""),
            "totalGB": client.get("totalGB", 0),
            "usedTraffic": obj.get("usedTraffic", 0),
            "expiryTime": client.get("expiryTime", 0),
            "enable": client.get("enable", True),
        }

    @staticmethod
    def new_sub_id() -> str:
        return uuid.uuid4().hex

    async def create_client(self, gb: float, days: int, email: str = "",
                            inbound_ids: list = None, flow: str = None) -> tuple:
        import random, string
        if not email:
            for _ in range(5):
                email = "u" + "".join(random.choices(string.ascii_lowercase + string.digits, k=12))
                try:
                    existing = await self.get_client(email)
                    if existing:
                        email = ""
                        continue
                except Exception:
                    pass
                break
        sub_id = self.new_sub_id()
        traffic_bytes = int(gb * GB)
        expire_ms = int(time.time() * 1000) + int(days * DAY_MS)
        await self.add_client(email, sub_id, traffic_bytes, expire_ms, inbound_ids=inbound_ids, flow=flow)
        return email, sub_id

    async def renew_client(self, email: str, add_gb: int) -> None:
        c = await self.get_client(email)
        if not c:
            raise PanelError(f"Client not found: {email}")
        now_ms = int(time.time() * 1000)
        new_expire = now_ms + 30 * DAY_MS
        new_total = c["totalGB"] + add_gb * GB
        await self.update_client(
            email, c["subId"], int(new_total), new_expire,
            flow=c.get("flow", ""),
        )

    async def change_link(self, email: str) -> str:
        c = await self.get_client(email)
        if not c:
            raise PanelError(f"Client not found: {email}")
        new_sub = self.new_sub_id()
        new_uuid = str(uuid.uuid4())
        await self.update_client(
            email,
            new_sub,
            c["totalGB"],
            c["expiryTime"],
            client_id=new_uuid,
            flow=c.get("flow", ""),
        )
        return new_sub

    def sub_url(self, sub_id: str) -> str:
        return f"{cfg.sub_base_url}/{sub_id}"

    @staticmethod
    def bytes_to_gb(b: int) -> float:
        return round(b / GB, 2)

    @staticmethod
    def remaining_days(expire_ms: int) -> int:
        if not expire_ms:
            return 0
        remaining = expire_ms - int(time.time() * 1000)
        return max(0, remaining // DAY_MS)

    @staticmethod
    def expire_date(expire_ms: int) -> str:
        from datetime import datetime, timezone
        if not expire_ms:
            return "نامحدود"
        return datetime.fromtimestamp(expire_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d")


panel = PanelClient()