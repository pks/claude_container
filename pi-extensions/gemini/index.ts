import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

// Opt-in diagnostic for pi-gemini. When PI_GEMINI_DEBUG is set to a truthy
// value, dumps the outgoing payload (via before_provider_request) and the raw
// HTTP response (via a fetch wrapper) for every generativelanguage.googleapis.com
// call to PI_GEMINI_DEBUG_LOG. Useful for catching new Gemini incompatibilities
// the same way the `store`/thought_signature bugs were caught — but off by
// default so production runs don't accumulate logs.

const LOG_PATH = process.env.PI_GEMINI_DEBUG_LOG ?? "/workspace/log/gemini-debug.log";
const ENABLED = /^(1|true|yes|on)$/i.test(process.env.PI_GEMINI_DEBUG ?? "");
const URL_MATCH = /generativelanguage\.googleapis\.com/;
const SENTINEL = Symbol.for("diffusemt.geminiDebugFetchPatched");

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
  if (!ENABLED) return;

  installFetchLogger();

  pi.on("before_provider_request", (event) => {
    const payload = (event as { payload?: unknown }).payload;
    logLine("REQUEST payload", safeStringify(payload));
  });

  process.stderr.write(`[gemini-debug] logging to ${LOG_PATH}\n`);
}
