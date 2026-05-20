import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

// Debug-only extension. Captures the outgoing request payload via pi's
// before_provider_request hook and the raw HTTP response (status + body) via
// a fetch wrapper scoped to the Gemini base URL prefix. Both are appended to
// /workspace/log/gemini-debug.log so we can see exactly what Gemini is
// rejecting when it returns the body-less 400. Remove once the root cause is
// identified.

const LOG_PATH = process.env.PI_GEMINI_DEBUG_LOG ?? "/workspace/log/gemini-debug.log";
const BASE_URL_PREFIX = "https://generativelanguage.googleapis.com/v1beta/openai";
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
    if (!url.startsWith(BASE_URL_PREFIX)) return originalFetch(input, init);

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
    const payload = (event as { payload?: unknown }).payload;
    logLine("REQUEST payload", safeStringify(payload));
  });

  process.stderr.write(`[gemini-debug] logging to ${LOG_PATH}\n`);
}
