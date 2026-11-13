"""Read a China-only snapshot with the saved session used by garmin-mcp-cn.

Reference: https://github.com/BorisBW/garmin-mcp-cn (9cceb64),
src/garmin_mcp/auth_cli.py and token_utils.py. No MCP server is required to read.
"""

import json
import argparse
import logging
import math
import signal
from datetime import datetime, timedelta
from pathlib import Path
from garmin_session import restore, save

try:
    from garminconnect import Garmin, GarminConnectAuthenticationError, GarminConnectConnectionError
except ImportError:
    if __name__ == "__main__":
        raise SystemExit(3) from None
    raise


def record(value):
    return value if isinstance(value, dict) else {}


def number(value):
    if type(value) in (int, float) and math.isfinite(value) and value >= 0:
        return round(value)
    return None


def optional(fetch, *args):
    try:
        return record(fetch(*args))
    except GarminConnectConnectionError:
        return {}


def stress_buckets(days, start, end):
    bucket_ms = 15 * 60 * 1000
    start_ms = int(start.timestamp() * 1000)
    end_ms = int(end.timestamp() * 1000)
    buckets = [[] for _ in range(96)]
    for day in days:
        for sample in day.get("stressValuesArray") or []:
            if not isinstance(sample, list) or len(sample) < 2:
                continue
            timestamp, stress = map(number, sample[:2])
            if timestamp is None or stress is None or not 0 <= stress <= 100:
                continue
            if start_ms <= timestamp <= end_ms:
                index = min(len(buckets) - 1, (timestamp - start_ms) // bucket_ms)
                buckets[index].append(stress)
    return [round(sum(bucket) / len(bucket)) if bucket else None for bucket in buckets]


def fetch_snapshot(client, now):
    today = now.date().isoformat()
    start = now - timedelta(hours=24)
    stats = record(client.get_stats(today))
    sleep = optional(client.get_sleep_data, today)
    sleep_day = record(sleep.get("dailySleepDTO"))
    sleep_score = record(record(sleep_day.get("sleepScores")).get("overall"))
    hrv = number(sleep.get("avgOvernightHrv"))
    if hrv is None:
        summary = record(optional(client.get_hrv_data, today).get("hrvSummary"))
        hrv = number(summary.get("lastNightAvg"))
    resting_heart_rate = number(stats.get("restingHeartRate"))
    if resting_heart_rate is None:
        heart_rates = optional(client.get_heart_rates, today)
        resting_heart_rate = number(heart_rates.get("restingHeartRate"))
    stress_days = [optional(client.get_stress_data, day) for day in (start.date().isoformat(), today)]
    device = optional(client.get_device_last_used)
    uploaded = number(device.get("lastUsedDeviceUploadTime"))

    return {
        "fetched_at": int(now.timestamp()),
        "last_sync_at": uploaded // 1000 if uploaded else None,
        "steps": number(stats.get("totalSteps")),
        "step_goal": number(stats.get("dailyStepGoal")),
        "sleep_seconds": number(sleep_day.get("sleepTimeSeconds")),
        "sleep_score": number(sleep_score.get("value")),
        "body_battery": number(stats.get("bodyBatteryMostRecentValue")),
        "resting_heart_rate": resting_heart_rate,
        "hrv": hrv,
        "stress": stress_buckets(stress_days, start, now),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session-file", type=Path, required=True)
    options = parser.parse_args(argv)
    logging.disable(logging.CRITICAL)
    signal.alarm(35)
    client = Garmin(is_cn=True)
    client.garth.configure(timeout=7, retries=0)
    try:
        restore(client, options.session_file)
    except (GarminConnectAuthenticationError, OSError, ValueError):
        return 2
    except Exception:
        return 1

    try:
        snapshot = fetch_snapshot(client, datetime.now().astimezone())
        save(client, options.session_file)
    except GarminConnectAuthenticationError:
        return 2
    except Exception:
        return 1
    print(json.dumps(snapshot, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
