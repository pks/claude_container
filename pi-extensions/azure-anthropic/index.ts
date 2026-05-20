import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { installAzureRetryFetch } from "../_shared/retry-fetch.js";

function upgradeCacheTtlInPlace(value: unknown): void {
  if (Array.isArray(value)) {
    for (const item of value) upgradeCacheTtlInPlace(item);
    return;
  }
  if (value && typeof value === "object") {
    const obj = value as Record<string, unknown>;
    if (obj.type === "ephemeral") {
      obj.ttl = "1h";
      return;
    }
    for (const v of Object.values(obj)) upgradeCacheTtlInPlace(v);
  }
}

export default function (pi: ExtensionAPI) {
  const base = process.env.AZURE_BASE_URL;
  if (!base) {
    // Extensions load on every pi startup regardless of profile. pi-gemini /
    // pi-or runs don't set AZURE_BASE_URL — throw here would surface a loud
    // load error every time. Silently no-op instead; pi-azure's run.sh sets
    // the var explicitly and a missing value there would have failed earlier.
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

  // Upgrade every cache_control: { type: "ephemeral" } to ttl: "1h" so cached
  // prefixes survive long pauses between turns. 1h writes cost $10/M vs $6.25/M
  // for 5-min, but break-even is ~1.6 reads — easily met on multi-turn sessions.
  // Mutates event.payload in place so this works regardless of whether the hook
  // API uses the return value.
  pi.on("before_provider_request", (event) => {
    upgradeCacheTtlInPlace(event.payload);
  });

  installAzureRetryFetch(base);
}
