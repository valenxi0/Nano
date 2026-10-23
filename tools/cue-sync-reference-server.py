#!/usr/bin/env python3
"""A minimal Cue sync server: the contract in docs/cue-sync.md, in memory.

Use it as an example to copy into your own app, or to try Cue sync without one:

    python3 tools/cue-sync-reference-server.py --port 8765
    # In Nano: Settings > Cue > Sync > Custom > Connect > http://localhost:8765/mcp

Options:
    --token SECRET   require "Authorization: Bearer SECRET"
    --sse            answer with text/event-stream instead of JSON
    --oauth          require MCP sign-in (OAuth with PKCE). For testing only:
                     every sign-in is approved without asking anyone.
    --debug          add debug_* tools that act like a person using the app
                     (create, edit, delete, list, forget sessions); for tests
"""

import argparse
import base64
import hashlib
import json
import secrets
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

LOCK = threading.Lock()
STATE = {
    "projects": {"p1": "Inbox", "p2": "Work"},
    "tasks": {},  # task_id -> task dict, including deleted ones
    "version": 0,
    "next_id": 1,
    "sessions": set(),
    # --oauth
    "clients": {},  # client_id -> redirect_uris
    "codes": {},  # code -> (client_id, redirect_uri, code_challenge)
    "access": {},  # access token -> expiry time
    "refresh": set(),
}


def now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def touch(task):
    STATE["version"] += 1
    task["version"] = STATE["version"]
    task["updated_at"] = now()


def new_task(fields):
    task_id = "t%d" % STATE["next_id"]
    STATE["next_id"] += 1
    task = {
        "task_id": task_id,
        "external_id": None,
        "title": "",
        "notes": "",
        "project_id": "p1",
        "done": False,
        "deleted": False,
        "kind": "todo",
        "images": [],  # [{"name", "mime_type", "bytes"}]; the data itself is dropped here
    }
    task.update(fields)
    touch(task)
    STATE["tasks"][task_id] = task
    return task


def public(task):
    # Images go one way, Cue to app, so the change feed leaves them out.
    return {k: v for k, v in task.items() if k not in ("version", "images", "source")}


class ToolError(Exception):
    pass


def schema(properties=None, required=None):
    return {"type": "object", "properties": properties or {}, "required": required or []}


TOOLS = {
    "cue_describe": schema(),
    "cue_list_projects": schema(),
    "cue_upsert_task": schema(
        {
            "external_id": {"type": "string"},
            "source": {"type": "string"},
            "task_id": {"type": "string"},
            "title": {"type": "string"},
            "notes": {"type": "string"},
            "project_id": {"type": "string"},
            "done": {"type": "boolean"},
            "kind": {"type": "string", "enum": ["todo", "prompt", "idea", "link"]},
            "images": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {"name": {"type": "string"}, "mime_type": {"type": "string"}, "data": {"type": "string"}},
                },
            },
        },
        ["external_id", "source", "title", "done"],
    ),
    "cue_list_changes": schema({"since": {"type": "string"}, "project_ids": {"type": "array", "items": {"type": "string"}}}),
    "cue_delete_task": schema({"task_id": {"type": "string"}}, ["task_id"]),
}

DEBUG_TOOLS = {
    "debug_create_task": schema({"title": {"type": "string"}, "notes": {"type": "string"}, "project_id": {"type": "string"}, "done": {"type": "boolean"}}),
    "debug_edit_task": schema({"task_id": {"type": "string"}}, ["task_id"]),
    "debug_delete_task": schema({"task_id": {"type": "string"}}, ["task_id"]),
    "debug_list_tasks": schema(),
    "debug_forget_sessions": schema(),
    "debug_expire_tokens": schema(),
}


def call_tool(name, args):
    if name == "cue_describe":
        return {"name": "Reference Server", "protocol_version": 1, "capabilities": ["two_way", "all_kinds", "images"]}

    if name == "cue_list_projects":
        return {"projects": [{"project_id": k, "name": v} for k, v in STATE["projects"].items()]}

    if name == "cue_upsert_task":
        external = str(args["external_id"]).upper()
        source = args.get("source", "cue")
        fields = {"title": args.get("title", ""), "notes": args.get("notes", ""), "done": bool(args.get("done"))}
        if args.get("kind") in ("todo", "prompt", "idea", "link"):
            fields["kind"] = args["kind"]
        if isinstance(args.get("images"), list):
            # The whole set; an empty list removes them all.
            fields["images"] = [
                {"name": i.get("name"), "mime_type": i.get("mime_type"), "bytes": len(base64.b64decode(i.get("data") or ""))}
                for i in args["images"]
            ]
        if args.get("project_id"):
            if args["project_id"] not in STATE["projects"]:
                raise ToolError("no project %s" % args["project_id"])
            fields["project_id"] = args["project_id"]
        task = STATE["tasks"].get(args.get("task_id") or "")
        if task is None or task["deleted"]:
            # Dedupe on (source, external_id): a retried create updates.
            task = next(
                (t for t in STATE["tasks"].values()
                 if not t["deleted"] and t.get("source") == source and t["external_id"] == external),
                None,
            )
        if task is None:
            task = new_task(dict(fields, external_id=external, source=source))
        else:
            task.update(fields, external_id=external, source=source)
            touch(task)
        return {"task_id": task["task_id"], "updated_at": task["updated_at"]}

    if name == "cue_list_changes":
        since = int(args.get("since") or 0)
        requested = args.get("project_ids") or []
        changed = [public(t) for t in STATE["tasks"].values() if t["version"] > since]
        return {
            "tasks": changed,
            "cursor": str(STATE["version"]),
            "missing_project_ids": [p for p in requested if p not in STATE["projects"]],
        }

    if name == "cue_delete_task":
        task = STATE["tasks"].get(args["task_id"])
        if task and not task["deleted"]:
            task["deleted"] = True
            touch(task)
        return {}

    if name == "debug_create_task":
        return public(new_task({k: args[k] for k in ("title", "notes", "project_id", "done", "kind") if k in args}))

    if name == "debug_edit_task":
        task = STATE["tasks"].get(args["task_id"])
        if task is None:
            raise ToolError("no task %s" % args["task_id"])
        task.update({k: args[k] for k in ("title", "notes", "project_id", "done", "kind") if k in args})
        touch(task)
        return public(task)

    if name == "debug_delete_task":
        return call_tool("cue_delete_task", args)

    if name == "debug_list_tasks":
        return {"tasks": [dict(public(t), images=t["images"]) for t in STATE["tasks"].values() if not t["deleted"]]}

    if name == "debug_forget_sessions":
        STATE["sessions"].clear()
        return {}

    if name == "debug_expire_tokens":
        STATE["access"].clear()
        return {}

    raise ToolError("unknown tool %s" % name)


class Handler(BaseHTTPRequestHandler):
    token = None
    sse = False
    debug = False
    oauth = False
    token_ttl = 3600

    def log_message(self, *args):
        pass

    def base(self):
        return "http://%s" % self.headers.get("Host", "localhost")

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        if self.oauth and url.path in ("/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"):
            return self.send_json(200, {"resource": self.base() + "/mcp", "authorization_servers": [self.base()], "scopes_supported": ["tasks"]})
        if self.oauth and url.path == "/.well-known/oauth-authorization-server":
            return self.send_json(200, {
                "issuer": self.base(),
                "authorization_endpoint": self.base() + "/authorize",
                "token_endpoint": self.base() + "/token",
                "registration_endpoint": self.base() + "/register",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"],
            })
        if self.oauth and url.path == "/authorize":
            query = {k: v[0] for k, v in parse_qs(url.query).items()}
            with LOCK:
                uris = STATE["clients"].get(query.get("client_id"))
                if uris is None or query.get("redirect_uri") not in uris:
                    return self.send_json(400, {"error": "invalid_request"})
                if query.get("code_challenge_method") != "S256" or not query.get("code_challenge"):
                    return self.send_json(400, {"error": "invalid_request", "error_description": "PKCE S256 required"})
                code = secrets.token_urlsafe(24)
                STATE["codes"][code] = (query["client_id"], query["redirect_uri"], query["code_challenge"])
            # Testing only: approve without asking.
            params = {"code": code}
            if query.get("state"):
                params["state"] = query["state"]
            self.send_response(302)
            self.send_header("Location", query["redirect_uri"] + "?" + urlencode(params))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # No server-initiated stream.
        self.send_response(405)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def oauth_post(self, path, raw):
        if path == "/register":
            body = json.loads(raw or b"{}")
            client_id = secrets.token_urlsafe(12)
            with LOCK:
                STATE["clients"][client_id] = list(body.get("redirect_uris") or [])
            return self.send_json(201, {"client_id": client_id, "redirect_uris": body.get("redirect_uris"), "token_endpoint_auth_method": "none"})
        form = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
        with LOCK:
            grant = form.get("grant_type")
            if grant == "authorization_code":
                entry = STATE["codes"].pop(form.get("code"), None)
                verifier = form.get("code_verifier", "")
                challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
                if entry is None or entry[0] != form.get("client_id") or entry[1] != form.get("redirect_uri") or entry[2] != challenge:
                    return self.send_json(400, {"error": "invalid_grant"})
            elif grant == "refresh_token":
                if form.get("refresh_token") not in STATE["refresh"]:
                    return self.send_json(400, {"error": "invalid_grant"})
                STATE["refresh"].discard(form["refresh_token"])
            else:
                return self.send_json(400, {"error": "unsupported_grant_type"})
            access, refresh = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
            STATE["access"][access] = time.time() + self.token_ttl
            STATE["refresh"].add(refresh)
        return self.send_json(200, {"access_token": access, "token_type": "Bearer", "expires_in": self.token_ttl, "refresh_token": refresh})

    def authorized(self):
        header = self.headers.get("Authorization") or ""
        if self.oauth:
            token = header[7:] if header.startswith("Bearer ") else ""
            with LOCK:
                return STATE["access"].get(token, 0) > time.time()
        return not self.token or header == "Bearer %s" % self.token

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        path = urlparse(self.path).path
        if self.oauth and path in ("/register", "/token"):
            return self.oauth_post(path, raw)
        if not self.authorized():
            self.send_response(401)
            if self.oauth:
                self.send_header("WWW-Authenticate", 'Bearer resource_metadata="%s/.well-known/oauth-protected-resource/mcp"' % self.base())
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        try:
            message = json.loads(raw)
        except ValueError:
            return self.reply(400)

        method = message.get("method")
        session = self.headers.get("Mcp-Session-Id")
        with LOCK:
            if method == "initialize":
                session = str(uuid.uuid4())
                STATE["sessions"].add(session)
                result = {
                    "protocolVersion": message.get("params", {}).get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "cue-sync-reference-server", "version": "1"},
                }
                return self.reply(200, message, result=result, session=session)
            if not session:
                return self.reply(400)
            if session not in STATE["sessions"]:
                return self.reply(404)
            if "id" not in message:
                return self.reply(202)
            if method == "tools/list":
                tools = dict(TOOLS, **(DEBUG_TOOLS if self.debug else {}))
                result = {"tools": [{"name": n, "inputSchema": s} for n, s in tools.items()]}
                return self.reply(200, message, result=result)
            if method == "tools/call":
                params = message.get("params", {})
                name = params.get("name", "")
                if name.startswith("debug_") and not self.debug:
                    name = "unknown"
                try:
                    data = call_tool(name, params.get("arguments") or {})
                    result = {"content": [{"type": "text", "text": json.dumps(data)}], "structuredContent": data, "isError": False}
                except (ToolError, KeyError, ValueError) as error:
                    result = {"content": [{"type": "text", "text": str(error)}], "isError": True}
                return self.reply(200, message, result=result)
            return self.reply(200, message, error={"code": -32601, "message": "Method not found"})

    def reply(self, status, message=None, result=None, error=None, session=None):
        if message is None:
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = {"jsonrpc": "2.0", "id": message.get("id")}
        if error is not None:
            body["error"] = error
        else:
            body["result"] = result
        payload = json.dumps(body)
        if self.sse:
            data = ("event: message\ndata: %s\n\n" % payload).encode()
            content_type = "text/event-stream"
        else:
            data = payload.encode()
            content_type = "application/json"
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if session:
            self.send_header("Mcp-Session-Id", session)
        self.end_headers()
        self.wfile.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token")
    parser.add_argument("--sse", action="store_true")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--oauth", action="store_true")
    parser.add_argument("--token-ttl", type=int, default=3600)
    args = parser.parse_args()
    Handler.token = args.token
    Handler.sse = args.sse
    Handler.debug = args.debug
    Handler.oauth = args.oauth
    Handler.token_ttl = args.token_ttl
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print("Cue sync reference server on http://localhost:%d/mcp" % server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
