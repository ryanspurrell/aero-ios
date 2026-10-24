#!/usr/bin/env python3
"""Writes AeroTests/Fixtures/device_signing/vectors.json: what the Messages store itself says an approval and a removal are signed over, and
signatures made over them that its own `verify` accepts, for fixed invented keys (the same keys as Fixtures/chat_crypto/vectors.json).

The Swift tests (DeviceSigningTests) check that the app writes the same texts byte for byte, and that it accepts these signatures with the
public key (ECDSA P-256 over SHA-256, the 64 bytes r then s, base64url). A signature made by the app cannot be compared byte for byte, since
ECDSA signatures differ each time; the server's check of such a signature is the one in this file (`verify` on a signature made over the same
text), and the app's own signing is verified in Swift with the same key.

    python3 tools/device_signing_vectors.py --bin /path/to/the/folder/holding/fingus_messages_store.py

Nothing here is from a real person.
"""
import argparse
import importlib.util
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.expanduser("~/.local/bin"))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "AeroTests", "Fixtures", "device_signing", "vectors.json"))
    a = ap.parse_args()
    os.environ["HOME"] = tempfile.mkdtemp(prefix="fakehome-")
    sys.path.insert(0, a.bin)
    spec = importlib.util.spec_from_file_location("fingus_messages_store", os.path.join(a.bin, "fingus_messages_store.py"))
    S = importlib.util.module_from_spec(spec)
    sys.modules["fingus_messages_store"] = S
    spec.loader.exec_module(S)
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec, utils

    base = json.load(open(os.path.join(HERE, "..", "AeroTests", "Fixtures", "chat_crypto", "vectors.json")))["devices"]
    alice, bob = base["alice"], base["bob"]
    key = ec.derive_private_key(int(alice["sign_private_scalar_hex"], 16), ec.SECP256R1())

    def sign(text):
        r, s = utils.decode_dss_signature(key.sign(text.encode(), ec.ECDSA(hashes.SHA256())))
        return S.b64(r.to_bytes(32, "big") + s.to_bytes(32, "big")) if hasattr(S, "b64") else \
            __import__("base64").urlsafe_b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big")).rstrip(b"=").decode()

    ts = 1_700_000_000
    approve = S.approval_text(alice["person"], bob["device"], bob["ecdh_public"], bob["sign_public"], ts)
    remove = S.removal_text(alice["person"], bob["device"], ts)
    out = {
        "about": "Invented keys only. Written by tools/device_signing_vectors.py from the Messages store's own approval_text, removal_text and verify.",
        "person": alice["person"], "approver_device": alice["device"], "approver_sign_public": alice["sign_public"],
        "approver_sign_private_scalar_hex": alice["sign_private_scalar_hex"],
        "target": {"device": bob["device"], "ecdh": bob["ecdh_public"], "sign": bob["sign_public"]},
        "ts": ts,
        "code": S.approval_code(bob["ecdh_public"], bob["sign_public"]), "code_vector_A_B": S.approval_code("A", "B"),
        "approval_text": approve, "approval_proof": sign(approve),
        "removal_text": remove, "removal_proof": sign(remove),
    }
    # The store itself, over a scratch database: both devices are registered as the app would (the first is trusted, the second waits), the
    # list is what Aero's /devices/mine.json makes from the store's rows (aero_web.devices_mine), and then the store is given these proofs.
    import types
    S.DB = os.path.join(os.environ["HOME"], "rooms.db")
    real_time = S.time
    S.time = types.SimpleNamespace(time=lambda: float(ts))
    try:
        S.register_device(alice["person"], alice["device"], alice["ecdh_public"], alice["sign_public"], "iPhone (Aero app)", draw=0)
        S.register_device(alice["person"], bob["device"], bob["ecdh_public"], bob["sign_public"], "Safari on iPhone", draw=1)
        rows = S.devices_all(alice["person"])
        out["devices_mine"] = {"now": float(ts), "devices": [
            {"device": r["device"], "name": r["name"], "kind": r["label"], "added": r["added"], "trusted": bool(r["trusted"]),
             "approved_by": r.get("approved_by"), "ecdh": r["ecdh"], "sign": r["sign"]} for r in rows]}
        assert [r["trusted"] for r in rows] == [True, False], rows
        assert S.approve_device(alice["person"], alice["device"], bob["device"], out["approval_proof"], ts, S.approval_code(bob["ecdh_public"], bob["sign_public"])) is True, "the store refused the approval"
        assert S.remove_device(alice["person"], bob["device"], alice["device"], out["removal_proof"], ts) is True, "the store refused the removal"
    finally:
        S.time = real_time
    for text, proof in ((approve, out["approval_proof"]), (remove, out["removal_proof"])):
        assert S.verify(alice["sign_public"], proof, text.encode()), "the store does not accept its own vector"
        assert not S.verify(alice["sign_public"], proof, (text + "x").encode()), "a changed text must not verify"
    assert not S.verify(alice["sign_public"], out["approval_proof"], remove.encode()), "an approval is not a removal"
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1, sort_keys=True)
        f.write("\n")
    print("wrote", a.out)


if __name__ == "__main__":
    main()
