"""Service catalog — static map ported from the Ballerina proxy catalog.bal.

Production would read this from a CMDB. All 7 mesh services with sync
dependency edges plus the async order->notification edge (NATS).
"""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class ServiceInfo:
    name: str
    owner: str
    slack_channel: str
    repo_url: str
    health_endpoint: str
    dependencies: tuple[str, ...]
    runbook_ids: tuple[str, ...]
    sla: str


SERVICE_CATALOG: dict[str, ServiceInfo] = {
    "store-service": ServiceInfo(
        "store-service", "store-team", "#store",
        "https://github.com/devopspoc/store-service", "http://store-service:9090/health",
        ("inventory-service",), ("restart-service", "disable-chaos"), "99.9%"),
    "customer-service": ServiceInfo(
        "customer-service", "customer-team", "#customer",
        "https://github.com/devopspoc/customer-service", "http://customer-service:9090/health",
        (), ("restart-service", "disable-chaos"), "99.95%"),
    "order-service": ServiceInfo(
        "order-service", "order-team", "#order",
        "https://github.com/devopspoc/order-service", "http://order-service:9090/health",
        ("customer-service", "inventory-service", "payment-service", "invoice-service", "notification-service"),
        ("restart-service", "disable-chaos", "freeze-deploys"), "99.9%"),
    "inventory-service": ServiceInfo(
        "inventory-service", "inventory-team", "#inventory",
        "https://github.com/devopspoc/inventory-service", "http://inventory-service:9090/health",
        (), ("restart-service", "disable-chaos", "clear-cache"), "99.9%"),
    "invoice-service": ServiceInfo(
        "invoice-service", "finance-team", "#finance",
        "https://github.com/devopspoc/invoice-service", "http://invoice-service:9090/health",
        (), ("restart-service", "disable-chaos"), "99.5%"),
    "payment-service": ServiceInfo(
        "payment-service", "payments-team", "#payments",
        "https://github.com/devopspoc/payment-service", "http://payment-service:9090/health",
        (), ("restart-service", "disable-chaos"), "99.99%"),
    "notification-service": ServiceInfo(
        "notification-service", "platform-team", "#platform",
        "https://github.com/devopspoc/notification-service", "http://notification-service:9090/health",
        (), ("restart-service", "disable-chaos"), "99.5%"),
}

# Async edges — order->notification via NATS (not in sync dependencies above).
ASYNC_EDGES: dict[str, tuple[str, ...]] = {"order-service": ("notification-service",)}


def catalog_lookup(name: str) -> ServiceInfo | None:
    return SERVICE_CATALOG.get(name)


def list_all_services() -> list[str]:
    return list(SERVICE_CATALOG.keys())


def get_dependencies(name: str, direction: str) -> list[str]:
    svc = SERVICE_CATALOG.get(name)
    if svc is None:
        return []
    if direction == "downstream":
        return list(svc.dependencies) + list(ASYNC_EDGES.get(name, ()))
    if direction == "upstream":
        up: list[str] = []
        for sn, si in SERVICE_CATALOG.items():
            if sn == name:
                continue
            if name in si.dependencies and sn not in up:
                up.append(sn)
            elif name in ASYNC_EDGES.get(sn, ()) and sn not in up:
                up.append(sn)
        return up
    # "both"
    return get_dependencies(name, "downstream") + get_dependencies(name, "upstream")
