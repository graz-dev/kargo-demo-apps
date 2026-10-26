#!/usr/bin/env python3
"""A tiny mock of the GitHub Packages endpoints that scripts/teardown.sh uses, for tests only.

  mock-github-api.py <seed.json> <token> <port>

The seed is a JSON list of {"id": int, "name": "sha256:...", "tags": [..]}. Authorization must be "Bearer <token>".
Routes: GET /users/<o> (and /orgs/<o> owners via the "testorg" name), GET .../versions?per_page&page,
DELETE .../versions/<id>, GET /__state (ids still present).
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

seed_path, token, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
versions = json.load(open(seed_path))
VERSIONS_RE = re.compile(r"^/(users|orgs)/([^/]+)/packages/container/([^/]+)/versions(?:/(\d+))?$")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # keep the test output quiet
        pass

    def reply(self, status, body=None):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        return self.headers.get("Authorization") == f"Bearer {token}"

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/__state":
            return self.reply(200, [v["id"] for v in versions])
        owner = re.match(r"^/users/([^/]+)$", path)
        if owner:
            return self.reply(200, {"type": "Organization" if owner.group(1) == "testorg" else "User"})
        m = VERSIONS_RE.match(path)
        if not m or m.group(4):
            return self.reply(404, {"message": "Not Found"})
        if not self.authorized():
            return self.reply(401, {"message": "Bad credentials"})
        params = dict(p.split("=") for p in query.split("&") if "=" in p)
        per_page, page = int(params.get("per_page", 30)), int(params.get("page", 1))
        chunk = versions[(page - 1) * per_page : page * per_page]
        return self.reply(
            200,
            [{"id": v["id"], "name": v["name"], "metadata": {"package_type": "container", "container": {"tags": v["tags"]}}} for v in chunk],
        )

    def do_DELETE(self):
        m = VERSIONS_RE.match(self.path)
        if not m or not m.group(4):
            return self.reply(404, {"message": "Not Found"})
        if not self.authorized():
            return self.reply(401, {"message": "Bad credentials"})
        vid = int(m.group(4))
        before = len(versions)
        versions[:] = [v for v in versions if v["id"] != vid]
        return self.reply(204 if len(versions) < before else 404)


HTTPServer(("127.0.0.1", port), Handler).serve_forever()
