import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { installAzureRetryFetch } from "../_shared/retry-fetch.js";

// Cache TTL for every ephemeral marker. Default "1h": these runs interleave
// long training/eval bash (5–60min) and human idle between turns, so reuse
// gaps routinely exceed the 5-min window; 1h keeps the prefix warm across them
// (write $10/M vs $6.25/M for 5-min, break-even ~1.6 reads — easily met on
// multi-turn sessions). Set AZURE_CACHE_TTL=5m for a purely back-to-back
// workload with no long tool waits to shed the write premium. Anthropic only
// accepts "5m" | "1h"; anything else falls back to "1h".
function resolveCacheTtl(): "5m" | "1h" {
  return process.env.AZURE_CACHE_TTL === "5m" ? "5m" : "1h";
}

function upgradeCacheTtlInPlace(value: unknown, ttl: "5m" | "1h"): void {
  if (Array.isArray(value)) {
    for (const item of value) upgradeCacheTtlInPlace(item, ttl);
    return;
  }
  if (value && typeof value === "object") {
    const obj = value as Record<string, unknown>;
    if (obj.type === "ephemeral") {
      obj.ttl = ttl;
      return;
    }
    for (const v of Object.values(obj)) upgradeCacheTtlInPlace(v, ttl);
  }
}

export default function (pi: ExtensionAPI) {
  const base = process.env.AZURE_BASE_URL;
  // Extensions load on every pi startup regardless of profile. Only register
  // the anthropic provider when this run is actually an Azure *anthropic* run
  // — i.e. AZURE_BASE_URL and ANTHROPIC_API_KEY are both set (run.sh sets
  // exactly one of ANTHROPIC_API_KEY / OPENAI_API_KEY for pi-azure). Gating on
  // the key (not just the base) avoids registering a stray anthropic provider
  // on an openai run, which makes pi's model-resolver also try to resolve the
  // openai model under anthropic and emit a spurious "not found for provider
  // anthropic" warning. pi-gemini / pi-or runs set neither → silent no-op.
  if (!base || !process.env.ANTHROPIC_API_KEY) {
    return;
  }
  pi.registerProvider("anthropic", {
    baseUrl: `${base.replace(/\/$/, "")}/anthropic`,
    // 1h TTL is gated behind a beta flag; without it the server ignores or
    // rejects ttl: "1h" on cache_control markers.
    headers: {
      "anthropic-beta": "extended-cache-ttl-2025-04-11",
    },
  });

  // Upgrade every cache_control: { type: "ephemeral" } to the resolved ttl so
  // cached prefixes survive long pauses between turns. Resolve once at register
  // time (env is fixed for the run). Mutates event.payload in place so this
  // works regardless of whether the hook API uses the return value.
  const ttl = resolveCacheTtl();
  pi.on("before_provider_request", (event) => {
    upgradeCacheTtlInPlace(event.payload, ttl);
  });

  installAzureRetryFetch(base);
}
