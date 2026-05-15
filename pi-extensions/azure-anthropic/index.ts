import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

function upgradeCacheTtl(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(upgradeCacheTtl);
  if (value && typeof value === "object") {
    const obj = value as Record<string, unknown>;
    const isCacheControl =
      obj.type === "ephemeral" &&
      Object.prototype.hasOwnProperty.call(obj, "type") &&
      !Array.isArray(obj);
    if (isCacheControl) {
      return { ...obj, ttl: "1h" };
    }
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(obj)) {
      out[k] = upgradeCacheTtl(v);
    }
    return out;
  }
  return value;
}

export default function (pi: ExtensionAPI) {
  const base = process.env.AZURE_BASE_URL;
  if (!base) throw new Error("AZURE_BASE_URL is not set");
  pi.registerProvider("anthropic", {
    baseUrl: `${base.replace(/\/$/, "")}/anthropic`,
  });

  // Upgrade every cache_control: { type: "ephemeral" } to ttl: "1h" so cached
  // prefixes survive long pauses between turns. 1h writes cost $10/M vs $6.25/M
  // for 5-min, but break-even is ~1.6 reads — easily met on multi-turn sessions.
  pi.on("before_provider_request", (event) => upgradeCacheTtl(event.payload));
}
