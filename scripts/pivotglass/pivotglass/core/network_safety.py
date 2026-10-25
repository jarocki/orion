"""Network binding policy shared by local Pivotglass services."""

from __future__ import annotations

import ipaddress


def require_loopback_host(host: str) -> str:
    """Normalize *host* and reject any non-loopback bind target."""

    normalized = host.strip().lower()
    if normalized == "localhost":
        # Bind the literal address so resolver configuration cannot redirect
        # the special local name to a non-loopback interface.
        return "127.0.0.1"
    try:
        address = ipaddress.ip_address(normalized)
    except ValueError as exc:
        raise ValueError(
            "Pivotglass web cockpit is loopback-only; host must be localhost "
            "or a loopback IP address."
        ) from exc
    if not address.is_loopback:
        raise ValueError(
            "Pivotglass web cockpit is loopback-only; host must be localhost "
            "or a loopback IP address."
        )
    return normalized
