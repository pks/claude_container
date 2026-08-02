// Idempotent retry wrapper around globalThis.fetch, scoped to the Azure base URL.
//
// Azure's Anthropic/OpenAI surfaces occasionally return spurious 404s, 429s,
// and 5xx — both SDKs (@anthropic-ai/sdk, openai) retry 408/409/429/>=500 by
// default but NOT 404, which is the most common transient failure we see.
// The user's workaround was to type "continue" after each failure; this
// wrapper does the same automatically, including when compaction is mid-flight.
//
// Only the initial response is retried. Once a 200 is returned and the SSE
// stream begins, mid-stream errors are the SDK's problem — partial output
// has already been emitted.

const SENTINEL = Symbol.for("diffusemt.azureRetryFetchPatched");
const RETRY_STATUSES = new Set([408, 425, 429, 500, 502, 503, 504, 524]);
// 15 attempts with 120s cap on per-sleep gives ~14min worst-case budget for
// 5xx/429 — enough to ride out scaling events and short throttle windows.
const MAX_ATTEMPTS = 15;
const MAX_SLEEP_MS = 120_000;
// 404 retries are capped lower so real config errors (wrong deployment name)
// surface in ~2min instead of holding the prompt for the full 15min budget.
const MAX_404_RETRIES = 8;

// Azure's AI-Foundry Responses endpoint strictly validates every `input[]`
// item's `type` against an enum; pi-ai (through 0.82.1) still omits `type` on
// some items, which serializes as `""` and Azure rejects with a 400. The
// azure-openai extension's `before_provider_request` hook patches the *main*
// turn payload, but pi's auto-compaction issues its OWN summarization request
// that bypasses that hook — so its `input[].type=''` items reach Azure raw and
// 400 ("invalid_value" on input[N]), which fails compaction and eventually
// wedges the agent. Normalizing here in the fetch layer covers EVERY request
// to the Azure base (main turns, compaction, tool loops) from one place.
//
// Guarded on a top-level `input` array so this only touches OpenAI Responses
// payloads; Azure *anthropic* bodies (which use `messages`) are left untouched.
function normalizeOpenAIInputTypes(body: string): string {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return body;
  }
  if (!parsed || typeof parsed !== "object") return body;
  const input = (parsed as Record<string, unknown>).input;
  if (!Array.isArray(input)) return body;
  let changed = false;
  for (const raw of input) {
    if (!raw || typeof raw !== "object") continue;
    const it = raw as Record<string, unknown>;
    if (typeof it.type === "string" && it.type !== "") continue;
    if ("call_id" in it && "output" in it) it.type = "function_call_output";
    else if ("call_id" in it && ("arguments" in it || "name" in it)) it.type = "function_call";
    else if ("summary" in it || "encrypted_content" in it) it.type = "reasoning";
    else if ("role" in it && "content" in it) it.type = "message";
    else it.type = "message";
    changed = true;
  }
  return changed ? JSON.stringify(parsed) : body;
}

function isReplayableBody(body: unknown): boolean {
  if (body == null) return true;
  if (typeof body === "string") return true;
  if (body instanceof URLSearchParams) return true;
  if (body instanceof ArrayBuffer) return true;
  if (ArrayBuffer.isView(body as ArrayBufferView)) return true;
  return false;
}

function abortableSleep(ms: number, signal?: AbortSignal | null): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(new DOMException("Aborted", "AbortError"));
    const onAbort = () => {
      clearTimeout(timer);
      reject(new DOMException("Aborted", "AbortError"));
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

function shouldRetry(status: number, attempt: number): boolean {
  if (RETRY_STATUSES.has(status)) return true;
  if (status === 404 && attempt < MAX_404_RETRIES) return true;
  return false;
}

function backoffMs(attempt: number): number {
  const base = Math.min(MAX_SLEEP_MS, 500 * 2 ** attempt);
  return Math.round(base * (0.75 + Math.random() * 0.5));
}

export function installAzureRetryFetch(azureBaseUrl: string): void {
  const current = globalThis.fetch as unknown as { [k: symbol]: unknown };
  if (current && current[SENTINEL]) return;

  const originalFetch = globalThis.fetch.bind(globalThis);
  const prefix = azureBaseUrl.replace(/\/$/, "");

  const wrapped = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url =
      typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    if (!url.startsWith(prefix)) return originalFetch(input, init);

    const signal = init?.signal ?? (input instanceof Request ? input.signal : undefined);
    if (!isReplayableBody(init?.body)) return originalFetch(input, init);

    // Patch `input[].type=''` on the serialized body (covers compaction, which
    // bypasses the extension's before_provider_request hook). Only rebuilds
    // init when the body is a string and actually changed; otherwise untouched.
    if (typeof init?.body === "string") {
      const normalized = normalizeOpenAIInputTypes(init.body);
      if (normalized !== init.body) init = { ...init, body: normalized };
    }

    let lastResponse: Response | undefined;
    let lastError: unknown;
    for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
      if (signal?.aborted) throw new DOMException("Aborted", "AbortError");
      try {
        const response = await originalFetch(input, init);
        if (response.ok || !shouldRetry(response.status, attempt)) return response;
        // Drain body so the socket can be reused.
        try {
          await response.arrayBuffer();
        } catch {}
        lastResponse = response;
        lastError = undefined;
      } catch (err) {
        if (signal?.aborted) throw err;
        lastError = err;
        lastResponse = undefined;
      }
      if (attempt === MAX_ATTEMPTS - 1) break;
      const wait = backoffMs(attempt);
      const reason = lastResponse ? `HTTP ${lastResponse.status}` : String(lastError);
      process.stderr.write(`[azure-retry] ${reason} — retrying in ${wait}ms (attempt ${attempt + 2}/${MAX_ATTEMPTS})\n`);
      await abortableSleep(wait, signal);
    }
    if (lastResponse) return lastResponse;
    throw lastError;
  }) as typeof fetch;

  (wrapped as unknown as { [k: symbol]: unknown })[SENTINEL] = true;
  globalThis.fetch = wrapped;
}
