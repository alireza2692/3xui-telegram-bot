import json
import sys
import argparse

def list_inbounds(json_str):
    try:
        data = json.loads(json_str)
    except Exception:
        print("EMPTY")
        return
    obj = data.get("obj", [])
    if not obj:
        print("EMPTY")
    else:
        for inb in obj:
            remark = inb.get("remark") or f"inbound-{inb.get('id')}"
            protocol = inb.get("protocol", "?")
            port = inb.get("port", "?")
            print(f"id={inb.get('id')}  [{protocol}]  port={port}  remark=\"{remark}\"")

def validate_inbound(json_str, want_id):
    try:
        data = json.loads(json_str)
    except Exception:
        print("INVALID")
        return
    obj = data.get("obj", [])
    found = None
    for inb in obj:
        if str(inb.get("id")) == str(want_id):
            found = inb
            break
    if found is None:
        print("INVALID")
    else:
        remark = found.get("remark") or f"inbound-{found.get('id')}"
        ss_raw = found.get("streamSettings", {})
        if isinstance(ss_raw, str):
            try:
                ss = json.loads(ss_raw)
            except Exception:
                ss = {}
        else:
            ss = ss_raw or {}
        is_reality = "y" if ss.get("security") == "reality" else "n"
        print(f"{found.get('id')}|{remark}|{is_reality}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=["list", "validate"], required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--id", default="")
    args = parser.parse_args()

    if args.action == "list":
        list_inbounds(args.json)
    elif args.action == "validate":
        validate_inbound(args.json, args.id)