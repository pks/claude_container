import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { installAzureRetryFetch } from "../_shared/retry-fetch.js";

// Azure's OpenAI Responses API occasionally streams a `response.failed` SSE
// event with no details, which pi-ai surfaces as this exact string. pi's
// built-in auto-retry regex doesn't match it, so the user has to type
// "continue". By prefixing with a phrase pi's regex DOES match
// ("provider returned error"), pi's existing exponential-backoff retry takes
// over. Backoff is configured in settings.json (baked into the image) to
// roughly match retry-fetch.ts's schedule: 500ms base, ~11 retries → ~17 min.
const AZURE_TRANSIENT_PATTERNS = [/no error details in response/i];

export default function (pi: ExtensionAPI) {
  const base = process.env.AZURE_BASE_URL;
  if (!base) {
    // See azure-anthropic for rationale: silently skip when not on the
    // pi-azure profile so other profiles' startup stays quiet.
    return;
  }
  pi.registerProvider("openai", {
    baseUrl: `${base.replace(/\/$/, "")}/openai/v1`,
  });

  installAzureRetryFetch(base);

  pi.on("message_end", (event) => {
    const msg = event.message as {
      role: string;
      stopReason?: string;
      errorMessage?: string;
    };
    if (msg.role !== "assistant" || msg.stopReason !== "error" || !msg.errorMessage) return;
    if (AZURE_TRANSIENT_PATTERNS.some((p) => p.test(msg.errorMessage!))) {
      msg.errorMessage = `provider returned error: ${msg.errorMessage}`;
    }
  });
}
