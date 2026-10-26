#!/usr/bin/env python3
"""Minimal client for the GitHub Packages REST API (container packages), standard library only.

  ghcr-packages.py owner-type <owner>                       -> "user" or "org"
  ghcr-packages.py list   <owner> <package>                  -> one line per version: id<TAB>name<TAB>tags (comma separated)
  ghcr-packages.py delete <owner> <package> <version-id>     -> deletes one version

Token: GITHUB_TOKEN (a classic token with read:packages and delete:packages).
API:   GITHUB_API_URL (default https://api.github.com; tests point it at a local mock).
Docs:  https://docs.github.com/en/rest/packages/packages
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
TOKEN = os.environ.get("GITHUB_TOKEN", "")


def die(msg):
    print(f"ERROR {msg}", file=sys.stderr)
    sys.exit(1)


def call(method, path, auth=True):
    req = urllib.request.Request(API + path, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if auth:
        req.add_header("Authorization", f"Bearer {TOKEN}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read()
            return resp.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as err:
        return err.code, None
    except urllib.error.URLError as err:
        die(f"cannot reach {API}: {err.reason}")


def explain(status, what):
    if status == 401:
        die(f"{what}: the token was refused (HTTP 401). Check GITHUB_TOKEN.")
    if status == 403:
        die(f"{what}: forbidden (HTTP 403). The token needs the read:packages and delete:packages scopes, and for an "
            "organization you must be an admin of the package. A public package version with more than 5,000 downloads "
            "cannot be deleted through the API.")
    if status == 404:
        die(f"{what}: not found (HTTP 404). Check the owner and package name, and that the token can see the package.")
    die(f"{what}: unexpected HTTP {status}.")


def base(owner):
    status, data = call("GET", f"/users/{urllib.parse.quote(owner)}", auth=False)
    if status != 200 or not data:
        explain(status, f"looking up {owner}")
    return "orgs" if data.get("type") == "Organization" else "users"


def main():
    if len(sys.argv) < 3:
        die(__doc__)
    cmd, owner = sys.argv[1], sys.argv[2]
    if not TOKEN and cmd != "owner-type":
        die("GITHUB_TOKEN is not set. Export a classic token with read:packages and delete:packages.")
    kind = base(owner)
    if cmd == "owner-type":
        print("org" if kind == "orgs" else "user")
        return
    if len(sys.argv) < 4:
        die(__doc__)
    package = urllib.parse.quote(sys.argv[3], safe="")
    root = f"/{kind}/{urllib.parse.quote(owner)}/packages/container/{package}"
    if cmd == "list":
        page = 1
        while True:
            status, data = call("GET", f"{root}/versions?per_page=100&page={page}")
            if status != 200:
                explain(status, "listing package versions")
            if not data:
                break
            for v in data:
                tags = ((v.get("metadata") or {}).get("container") or {}).get("tags") or []
                print(f"{v['id']}\t{v.get('name', '')}\t{','.join(tags)}")
            if len(data) < 100:
                break
            page += 1
    elif cmd == "delete":
        if len(sys.argv) < 5:
            die(__doc__)
        status, _ = call("DELETE", f"{root}/versions/{sys.argv[4]}")
        if status == 404:
            print(f"version {sys.argv[4]} was already gone")
        elif status not in (200, 204):
            explain(status, f"deleting version {sys.argv[4]}")
    else:
        die(f"unknown command {cmd}")


main()
