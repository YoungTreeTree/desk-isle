"""China-only login bridge, based on BorisBW/garmin-mcp-cn auth_cli.py (9cceb64).

Credentials/MFA arrive on stdin; stdout contains only bounded status events.
OAuth sessions go directly to app-owned storage. Passwords are never persisted.
"""
import argparse
import contextlib
import json
import logging
import signal
import sys

from garminconnect import Garmin, GarminConnectAuthenticationError, GarminConnectTooManyRequestsError
from garmin_session import save


def emit(kind, **fields):
    print(json.dumps({"type": kind, **fields}, separators=(",", ":")), flush=True)


def receive():
    line = sys.stdin.readline(16385)
    if not line or len(line) > 16384 or not line.endswith("\n"):
        raise ValueError("Invalid input")
    value = json.loads(line)
    if not isinstance(value, dict):
        raise ValueError("Invalid input")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session-file", required=True)
    options = parser.parse_args(argv)
    logging.disable(logging.CRITICAL)

    def timeout(*_):
        raise TimeoutError()

    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(180)
    events = sys.stdout

    def get_mfa():
        # Garth invokes this synchronously: keep the same login process/session alive.
        with contextlib.redirect_stdout(events):
            emit("mfa")
        value = receive().get("code", "").strip()
        if not value or len(value) > 32:
            raise ValueError("Invalid code")
        return value

    try:
        credentials = receive()
        email = credentials.get("email", "").strip()
        password = credentials.get("password", "")
        if not email or not password or not isinstance(password, str):
            raise ValueError("Missing credentials")
        with contextlib.redirect_stdout(sys.stderr):
            client = Garmin(email=email, password=password, is_cn=True, prompt_mfa=get_mfa)
            client.garth.configure(timeout=10, retries=0)
            client.login()
            # A successful login must return a usable profile, not merely write token files.
            if not client.get_full_name():
                raise GarminConnectAuthenticationError("Profile unavailable")
            save(client, options.session_file)
        emit("success")
        return 0
    except GarminConnectTooManyRequestsError:
        emit("error", code="rate_limit")
    except GarminConnectAuthenticationError:
        emit("error", code="authentication")
    except TimeoutError:
        emit("error", code="timeout")
    except (ValueError, TypeError, AttributeError):
        emit("error", code="invalid")
    except Exception:
        emit("error", code="connection")
    finally:
        signal.alarm(0)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
