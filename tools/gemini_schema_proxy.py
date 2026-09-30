#!/usr/bin/env python3
"""Schema-sanitising proxy so opencode can drive Gemini with tool calls.

WHY THIS EXISTS. opencode builds its tool schemas with the Vercel AI SDK, which emits full JSON
Schema including $ref / $defs / additionalProperties / propertyNames / allOf / anyOf / oneOf.
Gemini's functionDeclarations format does not accept those fields, so every tool-calling turn
comes back with finish_reason MALFORMED_FUNCTION_CALL -- which opencode renders as the singularly
unhelpful `Error: Filtered`. In our run that was 30 failures and 0 scored candidates.

This is NOT specific to us: the same failure is reported against Cursor, gemini-cli, LangChain
deepagents and Google's own ADK. opencode issue #11479 documents exactly this and is closed
WITHOUT an official fix, recommending a filtering proxy -- which is what this is.

WHY IT IS NOT A SAFETY BYPASS. Nothing here touches safety settings, system instructions or
content. It rewrites the TOOL SCHEMA ONLY -- dropping JSON Schema keywords Gemini cannot parse
and inlining $refs so the same tool remains callable. The model's own filters are untouched.

Evidence it is the schema and not anything else: hand-written FLAT schemas succeed 12/12 against
this model at every reasoning effort, with the real agent card and a 23 KB payload. Only
opencode's generated schemas fail, and they fail identically through the direct Google endpoint
and through OpenRouter -- so the transport is not the problem, the schema is.

    python3 gemini_schema_proxy.py --port 8790 --upstream https://openrouter.ai/api/v1
"""
import argparse, copy, json, os, sys, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path            # used by the raw-tool dump below

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8790)
ap.add_argument("--upstream", default="https://openrouter.ai/api/v1",
                help="OpenAI-compatible base URL to forward to")
ap.add_argument("--log", default="/tmp/gemini_proxy.log")
a = ap.parse_args()

# JSON Schema keywords Gemini's functionDeclarations rejects.
DROP = {"$schema", "$id", "$ref", "$defs", "definitions", "additionalProperties",
        "propertyNames", "allOf", "anyOf", "oneOf", "not", "patternProperties",
        "unevaluatedProperties", "dependentSchemas", "if", "then", "else",
        "const", "examples", "default", "exclusiveMinimum", "exclusiveMaximum"}
# Types Gemini accepts; anything else is coerced to string so the tool stays callable.
OK_TYPES = {"object", "array", "string", "number", "integer", "boolean"}


_DUMPED = False


def log(msg):
    try:
        with open(a.log, "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass


def resolve_refs(node, defs, depth=0):
    """Inline $ref targets. Dropping a $ref without inlining would leave a property with no type
    at all, which Gemini also rejects -- so the reference has to be replaced, not deleted."""
    if depth > 12 or not isinstance(node, dict):
        return node
    if "$ref" in node and isinstance(node["$ref"], str):
        name = node["$ref"].rsplit("/", 1)[-1]
        target = defs.get(name)
        if isinstance(target, dict):
            merged = copy.deepcopy(target)
            for k, v in node.items():
                if k != "$ref":
                    merged.setdefault(k, v)
            return resolve_refs(merged, defs, depth + 1)
        return {"type": "string"}          # unresolvable -> keep the property callable
    return node


def clean(node, defs, depth=0):
    if depth > 12:
        return {"type": "string"}
    if isinstance(node, list):
        return [clean(x, defs, depth + 1) for x in node]
    if not isinstance(node, dict):
        return node
    node = resolve_refs(node, defs, depth)
    out = {}
    for k, v in node.items():
        if k in DROP:
            continue
        if k == "properties" and isinstance(v, dict):
            out[k] = {pk: clean(pv, defs, depth + 1) for pk, pv in v.items()}
        elif k == "items":
            out[k] = clean(v, defs, depth + 1)
        elif k == "type":
            if isinstance(v, list):                       # ["string","null"] -> "string"
                v = next((t for t in v if t in OK_TYPES and t != "null"), "string")
            out[k] = v if v in OK_TYPES else "string"
        else:
            out[k] = clean(v, defs, depth + 1) if isinstance(v, (dict, list)) else v
    # An object with no properties is rejected; give it an empty map rather than omitting it.
    if out.get("type") == "object" and "properties" not in out:
        out["properties"] = {}
    if "type" not in out and "properties" in out:
        out["type"] = "object"
    return out


# Models that REJECT `temperature` outright. claude-opus-5 answers
# "`temperature` is deprecated for this model" and fails the whole call. opencode sends a
# default temperature whenever the agent card omits one, so deleting it from the card does not
# help -- it only swaps our value for opencode's. There is no opencode setting to suppress it,
# so it has to be stripped in transit. Verified: the failure is identical via OpenRouter and via
# direct Anthropic, so this is about the FIELD, not the route.
# SUBSTRING match, so "claude-fable" covers claude-fable-5, claude-fable-5.1 (OpenRouter's
# spelling) and claude-fable-5-1 (Anthropic's own). Probed against api.anthropic.com before any
# Fable arm was launched: `temperature: 0.3` -> http 400 "`temperature` is deprecated for this
# model", byte-identical to opus-5. EVERY agent card in this repo sets temperature: 0.3, so a
# Fable arm without this entry would 400 on every call and burn all 200 turns with zero scored
# candidates -- precisely what happened to the opus arm before this list existed.
NO_TEMPERATURE = ("claude-opus-5", "claude-fable")


def strip_params(body):
    model = str(body.get("model") or "")
    dropped = []
    if any(m in model for m in NO_TEMPERATURE):
        for k in ("temperature", "top_p", "top_k"):
            if k in body:
                body.pop(k)
                dropped.append(k)
    return body, dropped


def sanitise(body):
    tools = body.get("tools")
    if not isinstance(tools, list):
        return body, 0
    n = 0
    for t in tools:
        fn = (t or {}).get("function") or {}
        params = fn.get("parameters")
        if not isinstance(params, dict):
            continue
        defs = params.get("$defs") or params.get("definitions") or {}
        fn["parameters"] = clean(params, defs)
        n += 1
    return body, n


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw or b"{}")
        except Exception:
            body = {}
        # Dump the FIRST request's raw tool schemas: this is the only way to see what opencode
        # actually emits. Every synthetic reproduction so far has succeeded, so the difference
        # lives in a payload we have never inspected.
        global _DUMPED
        if not _DUMPED and isinstance(body.get("tools"), list):
            _DUMPED = True
            try:
                Path("/tmp/gemini_raw_tools.json").write_text(json.dumps(body["tools"], indent=1))
                log(f"DUMPED {len(body['tools'])} raw tool schemas to /tmp/gemini_raw_tools.json")
            except Exception as e:
                log(f"dump failed: {e}")
        body, dropped = strip_params(body)
        body, n = sanitise(body)
        if dropped:
            log(f"stripped {dropped} for {body.get('model')}")
        payload = json.dumps(body).encode()

        url = a.upstream.rstrip("/") + self.path[len("/v1"):] if self.path.startswith("/v1") \
              else a.upstream.rstrip("/") + self.path
        req = urllib.request.Request(url, data=payload, method="POST")
        for h in ("authorization", "content-type", "accept", "x-api-key"):
            if self.headers.get(h):
                req.add_header(h, self.headers[h])
        req.add_header("Content-Length", str(len(payload)))
        try:
            with urllib.request.urlopen(req, timeout=900) as r:
                data = r.read()
                code = r.status
                ctype = r.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:
            data, code = e.read(), e.code
            ctype = "application/json"
        except Exception as e:
            data, code = json.dumps({"error": str(e)}).encode(), 502
            ctype = "application/json"

        # Record the finish reason so a residual MALFORMED_FUNCTION_CALL is visible rather than
        # silently rendered as "Filtered" by opencode.
        try:
            j = json.loads(data)
            fr = (j.get("choices") or [{}])[0].get("finish_reason")
            log(f"tools_sanitised={n} http={code} finish={fr}")
        except Exception:
            log(f"tools_sanitised={n} http={code} (non-JSON/stream)")

        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")


print(f"gemini schema proxy on :{a.port} -> {a.upstream}  (log {a.log})", flush=True)
ThreadingHTTPServer(("0.0.0.0", a.port), Handler).serve_forever()
