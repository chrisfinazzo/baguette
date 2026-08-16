#!/usr/bin/env python3
"""Deep links — type a URL, watch it land in your app.

Opening the panel lists every URL scheme the device's apps registered,
so the answer to "what can I even open here?" is on screen before you
type anything. Each row is a `rowAction: "run"` row, so clicking one
opens `scheme://` immediately; the field above submits to this same
command with whatever you typed.

The one thing this says that `xcrun simctl openurl` doesn't: an
`https://` link dispatches perfectly happily and then opens **Safari**,
because the simulator doesn't resolve associated domains the way a
device does. Every tool performs that silently, leaving you to wonder
whether your entitlement, your apple-app-site-association file or the
simulator is at fault. The server names the case; this reports it.

  in   BAGUETTE_URL / BAGUETTE_UDID / BAGUETTE_TOKEN in the environment,
       plus the typed text as {"args": {"url": …}} in the JSON on stdin
  out  one JSON object on stdout: {"ok": bool, "message"?, "rows": [...]}
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def answer(ok, rows=None, message=None):
    out = {"ok": ok, "rows": rows or []}
    if message:
        out["message"] = message
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")
    sys.exit(0)


def call(method, url, token):
    """One request against the running server. Raises on failure."""
    request = urllib.request.Request(
        url, headers={"X-Baguette-Token": token}, method=method
    )
    with urllib.request.urlopen(request, timeout=8) as response:
        return json.load(response)


def reason(error):
    """Why a call failed, in the server's own words where it has any.

    A route that answers `{"ok":false,"error":…}` knows more about the
    failure than we can infer from a status code — and reporting "the
    device isn't booted" when the real problem was a typo'd URL sends
    people looking in the wrong place entirely.
    """
    if isinstance(error, urllib.error.HTTPError):
        body = error.read().decode(errors="replace")
        try:
            said = json.loads(body).get("error")
        except ValueError:
            said = None
        if said:
            return said
        if error.code == 404:
            return (
                "This baguette has no deep-link routes — rebuild it (`make`) "
                "and restart `baguette serve`."
            )
        return f"HTTP {error.code}"
    return str(error)


def scheme_rows(base, udid, token):
    """One row per registered scheme, already ranked by the server."""
    url = f"{base}/simulators/{udid}/schemes.json"
    try:
        found = call("GET", url, token).get("schemes") or []
    except Exception as error:  # noqa: BLE001 - surfaced to the user verbatim
        # The inventory is a convenience, not the feature. If it can't be
        # read we still want the field above it to work, so this degrades
        # to a note rather than failing the whole panel.
        return [{
            "title": "Could not list URL schemes",
            "subtitle": reason(error),
            "severity": "warn",
        }]

    if not found:
        return [{
            "title": "No app here registers a URL scheme",
            "subtitle": "http:// and https:// still work — they open Safari",
            "severity": "info",
        }]

    # Each row *fills the field* rather than opening. A bare `account://`
    # with no path is almost never what anyone means to open — the list
    # is a completion source, so picking one puts it in the box with the
    # caret after it, ready for the rest of the URL.
    return [{
        "title": row.get("completion", ""),
        "subtitle": row.get("app", ""),
        "severity": "info",
        "fill": row.get("completion", ""),
    } for row in found]


def opened_row(url, answered):
    """What happened to the link we just dispatched."""
    if answered.get("routing") == "browser":
        return {
            "title": f"Opened {url} in Safari",
            "subtitle": answered.get(
                "warning", "This lands in Safari on the simulator, not your app."
            ),
            "severity": "warn",
        }
    return {
        "title": f"Opened {url}",
        "subtitle": "the app that registered this scheme came to the foreground",
        "severity": "info",
    }


def main():
    base = os.environ.get("BAGUETTE_URL")
    udid = os.environ.get("BAGUETTE_UDID")
    token = os.environ.get("BAGUETTE_TOKEN", "")
    if not base or not udid:
        answer(False, message="No device focused")

    # The typed text, when something was typed. Opening the panel sends
    # none, which means "just show me what's openable".
    try:
        context = json.load(sys.stdin)
    except Exception:  # noqa: BLE001 - stdin is optional
        context = {}
    url = ((context.get("args") or {}).get("url") or "").strip()

    if not url:
        answer(True, rows=scheme_rows(base, udid, token))

    target = (
        f"{base}/simulators/{udid}/openurl?url="
        + urllib.parse.quote(url, safe="")
    )
    try:
        answered = call("POST", target, token)
    except Exception as error:  # noqa: BLE001 - surfaced to the user verbatim
        answer(False, message=f"Could not open {url}: {reason(error)}")

    # The result first, then the inventory again — the panel stays a
    # control surface rather than becoming a one-line receipt.
    answer(True, rows=[opened_row(url, answered)] + scheme_rows(base, udid, token))


if __name__ == "__main__":
    main()
