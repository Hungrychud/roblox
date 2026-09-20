import sys, json, urllib.request

URL = "http://127.0.0.1:8765/mcp"

def call(method, params):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":method,"params":params}).encode()
    req = urllib.request.Request(URL, data=body, headers={
        "Content-Type":"application/json",
        "Accept":"application/json, text/event-stream",
    })
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())

def tool(name, args):
    d = call("tools/call", {"name":name,"arguments":args})
    if "error" in d:
        print("ERR:", d["error"]); return
    for c in d["result"].get("content", []):
        if c.get("type")=="text":
            print(c["text"])

if __name__ == "__main__":
    name = sys.argv[1]
    if name == "exec":
        code = sys.stdin.read()
        tool("matcha_exec", {"code": code})
    elif name == "search":
        args = {"query": sys.argv[2]}
        if len(sys.argv) > 3: args["className"] = sys.argv[3]
        tool("matcha_search", args)
    elif name == "tree":
        args = {"path": sys.argv[2]}
        if len(sys.argv) > 3: args["depth"] = int(sys.argv[3])
        tool("matcha_tree", args)
    elif name == "decompile":
        tool("matcha_decompile", {"path": sys.argv[2]})
    elif name == "logs":
        tool("matcha_logs", {})
    elif name == "status":
        tool("matcha_status", {})
    elif name == "scripts":
        tool("matcha_scripts", {"query": sys.argv[2] if len(sys.argv)>2 else ""})
    else:
        # generic: name + json args from stdin
        tool(name, json.loads(sys.stdin.read() or "{}"))
