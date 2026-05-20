import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

// Two responsibilities:
//
// 1. Strip OpenAI-only fields from outgoing payloads. pi-coding-agent's
//    openai-completions provider injects fields like `store` (an OpenAI
//    Responses-API control) that Gemini's OpenAI-compat layer rejects with
//    a 400 ("Unknown name \"store\": Cannot find field."). pi-ai surfaces the
//    rejection as a body-less error because its client doesn't unwrap the
//    gzip'd error body, so without this normalization every turn fails.
//
// 2. Log the request payload (via before_provider_request) and raw HTTP
//    response (via a fetch wrapper) to PI_GEMINI_DEBUG_LOG. Optional —
//    enable by leaving the default log path writable. Useful for catching
//    future incompatibilities the same way `store` was caught.

const LOG_PATH = process.env.PI_GEMINI_DEBUG_LOG ?? "/workspace/log/gemini-debug.log";
const URL_MATCH = /generativelanguage\.googleapis\.com/;
const SENTINEL = Symbol.for("diffusemt.geminiDebugFetchPatched");

// Fields pi-coding-agent sends that Gemini's OpenAI-compat layer rejects.
// Add to this list when a new incompatibility surfaces in the debug log.
const UNSUPPORTED_FIELDS = ["store"] as const;

function logLine(label: string, body: string): void {
  try {
    mkdirSync(dirname(LOG_PATH), { recursive: true });
    const ts = new Date().toISOString();
    appendFileSync(LOG_PATH, `\n===== ${ts} ${label} =====\n${body}\n`);
  } catch (err) {
    process.stderr.write(`[gemini-debug] log write failed: ${String(err)}\n`);
  }
}

function safeStringify(value: unknown): string {
  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value);
  }
}

function installFetchLogger(): void {
  const current = globalThis.fetch as unknown as { [k: symbol]: unknown };
  if (current && current[SENTINEL]) return;
  const originalFetch = globalThis.fetch.bind(globalThis);

  const wrapped = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url =
      typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (!URL_MATCH.test(url)) return originalFetch(input, init);

    const response = await originalFetch(input, init);
    // Tee the body so the SDK still sees an unread stream.
    const cloned = response.clone();
    cloned
      .text()
      .then((body) => {
        const headers: Record<string, string> = {};
        response.headers.forEach((v, k) => {
          headers[k] = v;
        });
        logLine(
          `RESPONSE ${response.status} ${url}`,
          `headers: ${safeStringify(headers)}\nbody (${body.length} bytes): ${body || "<empty>"}`,
        );
      })
      .catch((err) => {
        logLine(`RESPONSE-READ-ERROR ${url}`, String(err));
      });
    return response;
  }) as typeof fetch;

  (wrapped as unknown as { [k: symbol]: unknown })[SENTINEL] = true;
  globalThis.fetch = wrapped;
}

export default function (pi: ExtensionAPI) {
  installFetchLogger();

  pi.on("before_provider_request", (event) => {
    const payload = (event as { payload?: Record<string, unknown> }).payload;
    if (payload && typeof payload === "object") {
      for (const field of UNSUPPORTED_FIELDS) {
        if (field in payload) delete payload[field];
      }
    }
    logLine("REQUEST payload", safeStringify(payload));
  });

  process.stderr.write(`[gemini-debug] logging to ${LOG_PATH}\n`);
}
