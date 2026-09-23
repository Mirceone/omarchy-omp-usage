#!/usr/bin/env python3
"""Print the plan behind each account logged in to Oh My Pi.

OMP's `usage --json` carries the plan for some providers (Codex `planType`,
Copilot `plan`, Gemini `currentTierName`) but not for Claude or Cursor. This
reads OMP's credential store and asks those providers' own account APIs.
Tokens are only ever sent to the provider that issued them and never printed.

Output: {"<provider>|<accountId or email>": {"plan": str|null, "access": str}}
plus "<provider>|*" when a provider has exactly one account.
"""

import base64
import json
import os
import sqlite3
import sys
import time
import urllib.parse
import urllib.request

DB = os.path.expanduser("~/.omp/agent/agent.db")
TIMEOUT = 8

CLAUDE_TYPES = {
    "claude_pro": "Pro",
    "claude_team": "Team",
    "claude_enterprise": "Enterprise",
    "claude_free": "Free",
}

CURSOR_TYPES = {
    "free": "Free",
    "free_trial": "Pro trial",
    "pro": "Pro",
    "pro_plus": "Pro+",
    "ultra": "Ultra",
    "business": "Teams",
    "team": "Teams",
    "enterprise": "Enterprise",
}


def get_json(url, headers):
    request = urllib.request.Request(url, headers={"Accept": "application/json", **headers})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return json.load(response)


def claude_plan(data):
    token = data.get("access")
    if not token or data.get("expires", 0) <= time.time() * 1000:
        return None
    profile = get_json(
        "https://api.anthropic.com/api/oauth/profile",
        {"Authorization": f"Bearer {token}", "anthropic-beta": "oauth-2025-04-20"},
    )
    org = profile.get("organization") or {}
    kind = org.get("organization_type") or ""
    tier = org.get("rate_limit_tier") or ""
    if kind == "claude_max" or (profile.get("account") or {}).get("has_claude_max"):
        for size in ("20x", "5x"):
            if size in tier:
                return f"Max {size}"
        return "Max"
    if kind in CLAUDE_TYPES:
        return CLAUDE_TYPES[kind]
    if (profile.get("account") or {}).get("has_claude_pro"):
        return "Pro"
    return kind.replace("claude_", "").replace("_", " ").title() or None


def cursor_user_id(token):
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError):
        return None
    sub = str(claims.get("sub") or "")
    parts = sub.split("|")
    return (parts[1] if len(parts) > 1 else sub).strip() or None


def cursor_plan(data):
    token = data.get("access")
    if not token:
        return None
    kind = None
    try:
        kind = get_json("https://api2.cursor.sh/auth/full_stripe_profile",
                        {"Authorization": f"Bearer {token}"}).get("membershipType")
    except Exception:
        pass
    if not kind:
        user_id = cursor_user_id(token)
        if user_id:
            cookie = "WorkosCursorSessionToken=" + urllib.parse.quote(f"{user_id}::{token}")
            kind = get_json("https://cursor.com/api/usage-summary", {"Cookie": cookie}).get("membershipType")
    if not kind:
        return None
    return CURSOR_TYPES.get(kind, str(kind).replace("_", " ").title())


LOOKUPS = {"anthropic": claude_plan, "cursor": cursor_plan}


def main():
    if not os.path.exists(DB):
        print("{}")
        return
    connection = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    rows = connection.execute(
        "select provider, credential_type, data from auth_credentials where disabled_cause is null"
    ).fetchall()
    connection.close()

    plans = {}
    per_provider = {}
    for provider, credential_type, raw in rows:
        try:
            data = json.loads(raw)
        except ValueError:
            continue
        plan = None
        lookup = LOOKUPS.get(provider)
        if lookup and credential_type == "oauth":
            try:
                plan = lookup(data)
            except Exception as error:
                print(f"{provider}: {error}", file=sys.stderr)
        entry = {"plan": plan, "access": "Subscription" if credential_type == "oauth" else "API key"}
        for identity in (data.get("accountId"), data.get("email")):
            if identity:
                plans[f"{provider}|{identity}"] = entry
        per_provider.setdefault(provider, []).append(entry)
    for provider, entries in per_provider.items():
        if len(entries) == 1:
            plans[f"{provider}|*"] = entries[0]
    print(json.dumps(plans))


if __name__ == "__main__":
    main()
