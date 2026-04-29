import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const base = process.env.AZURE_BASE_URL;
  if (!base) throw new Error("AZURE_BASE_URL is not set");
  pi.registerProvider("anthropic", {
    baseUrl: `${base.replace(/\/$/, "")}/anthropic`,
  });
}
