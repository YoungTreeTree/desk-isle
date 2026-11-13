"""Private, atomic session storage shared by the China login and snapshot helpers."""
import base64
import json
import os
from pathlib import Path
import tempfile


def validate(pair):
    if not isinstance(pair, list) or len(pair) != 2 or not all(isinstance(p, dict) for p in pair):
        raise ValueError("Invalid session")
    if pair[0].get("domain") != "garmin.cn":
        raise ValueError("China session required")
    for item, fields in [(pair[0], ("oauth_token", "oauth_token_secret")),
                         (pair[1], ("access_token", "refresh_token"))]:
        if not all(isinstance(item.get(key), str) and item[key] for key in fields):
            raise ValueError("Incomplete session")
    return pair


def read(path):
    path = Path(path)
    if path.is_symlink() or path.stat().st_size > 131072:
        raise ValueError("Invalid session file")
    return validate(json.loads(path.read_text()))


def restore(client, path):
    pair = read(path)
    client.garth.loads(base64.b64encode(json.dumps(pair).encode()).decode())
    # Use the restored state for the regular profile validation path.
    client.login(client.garth.dumps())


def save(client, path):
    pair = validate(json.loads(base64.b64decode(client.garth.dumps(), validate=True)))
    path = Path(path)
    if path.is_symlink():
        raise ValueError("Invalid session file")
    # Never recreate the parent: logout removes it, invalidating in-flight reads.
    descriptor, temporary = tempfile.mkstemp(prefix=".session-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as output:
            json.dump(pair, output, separators=(",", ":"))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
