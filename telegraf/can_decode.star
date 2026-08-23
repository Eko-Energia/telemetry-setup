# Decode CAN messages from dbc-can-bridge into VictoriaMetrics metrics.
#
# Input: the "value"/"string" parser puts the whole MQTT payload as a string into
# the "value" field. This processor parses it with json.decode and handles BOTH
# shapes from the WebSocket API:
#   - "update"   -> single message:   { message_name, entry: { signals, timestamp } }
#   - "snapshot" -> map of messages:   { data: { <msg_name>: { signals, timestamp } } }
# Any other type (subscribe/raw/transmit) is dropped.
#
# "signals" may be empty or absent - heartbeat frames exist only to prove a board is
# alive. "timestamp" is always present.
#
# Output: "can_signal" metrics with a message tag, plus signal/unit tags for actual
# measurements. Every metric carries EXACTLY ONE field - the VM metric name depends
# on it via -influxSkipSingleField (see docker-compose.yml); a second field would
# silently rename every series.
#   can_signal{message="BMS_Status", signal="Battery_Voltage", unit="V"} 48.6
#   can_signal{message="Emergency"} 1                    <- signal-less frame

load("json.star", "json")
load("time.star", "time")

# Timestamp format emitted by the bridge: RFC3339 with nanoseconds and a zone
# offset, e.g. "2026-01-12T14:23:46.123456789+01:00" (or "...Z" for UTC).
TS_FORMAT = "2006-01-02T15:04:05.999999999Z07:00"

def apply(metric):
    payload = json.decode(metric.fields["value"])
    msg_type = payload.get("type")

    if msg_type == "update":
        return _emit(payload["message_name"], payload["entry"])

    if msg_type == "snapshot":
        out = []
        for message_name, entry in payload["data"].items():
            out.extend(_emit(message_name, entry))
        return out

    # unknown type -> drop the metric
    return None

def _emit(message_name, entry):
    ts = time.parse_time(entry["timestamp"], format=TS_FORMAT).unix_nano
    signals = entry.get("signals", [])

    if not signals:
        # Deliberately no "signal"/"unit" tags: this sample belongs to a frame, not
        # to a measurement. An absent label matches no non-trivial regex, so every
        # signal-scoped query skips it on its own. The 1.0 is the usual info-metric
        # convention - what you actually read is the timestamp, via timestamp().
        m = Metric("can_signal")
        m.tags["message"] = message_name
        m.fields["value"] = 1.0
        m.time = ts
        return [m]

    metrics = []
    for sig in signals:
        m = Metric("can_signal")
        m.tags["message"] = message_name
        m.tags["signal"] = sig["name"]
        m.tags["unit"] = sig["unit"]
        m.fields["value"] = float(sig["value"])
        m.time = ts
        metrics.append(m)
    return metrics
