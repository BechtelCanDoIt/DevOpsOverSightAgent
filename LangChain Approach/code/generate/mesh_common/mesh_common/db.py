"""Lazy infra clients — deliberate fix for the Ballerina boot-fatal gotcha.

The Ballerina services created module-level DB clients, which made `bal test`
require live infrastructure. Here every client is a lazy factory reading the
same env contract (`DB_*`, `REDIS_*`, `NATS_URL` with identical defaults), so
pytest runs infra-free with injected fakes and services degrade gracefully
when infra is still starting.
"""

from __future__ import annotations

from .obs import env_or

_pg_pool = None
_redis = None
_nats = None


async def pg_pool(default_db: str):
    """Shared asyncpg pool for this process (one service = one database)."""
    global _pg_pool
    if _pg_pool is None:
        import asyncpg

        _pg_pool = await asyncpg.create_pool(
            host=env_or("DB_HOST", "postgres"),
            port=int(env_or("DB_PORT", "5432")),
            user=env_or("DB_USER", "postgres"),
            password=env_or("DB_PASSWORD", "postgres"),
            database=env_or("DB_NAME", default_db),
            min_size=1,
            max_size=10,
        )
    return _pg_pool


def redis_client():
    """Shared redis asyncio client (inventory cache)."""
    global _redis
    if _redis is None:
        import redis.asyncio as aioredis

        _redis = aioredis.Redis(
            host=env_or("REDIS_HOST", "redis"),
            port=int(env_or("REDIS_PORT", "6379")),
            decode_responses=True,
        )
    return _redis


async def nats_connection():
    """Shared NATS connection (order publisher / notification subscriber)."""
    global _nats
    if _nats is None or _nats.is_closed:
        import nats

        _nats = await nats.connect(env_or("NATS_URL", "nats://nats:4222"))
    return _nats


def reset_clients() -> None:
    """Test hook: drop cached clients so fakes can be injected per test."""
    global _pg_pool, _redis, _nats
    _pg_pool = None
    _redis = None
    _nats = None
