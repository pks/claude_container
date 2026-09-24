// pi-side counterpart to ops/mithril-hook.sh.
//
// Claude Code learns about Mithril spot preemption via a PreToolUse hook
// (ops/claude-settings.json + ops/mithril-hook.sh) that injects
// additionalContext into the next tool call. pi has no PreToolUse hook,
// so this extension provides two delivery paths on the same signal file
// (until /workspace/.shutdown-acked appears):
//
//   (1) **Inline injection via before_provider_request** — the primary
//       path. While the signal is live, every outgoing LLM request gets
//       the preemption nudge appended as a user message. Guaranteed to
//       reach the agent on the very next LLM call, even if it's deep in
//       a tool-call loop (bash → result → next bash → …) where queued
//       follow-ups would never drain.
//
//   (2) **Queued sendUserMessage(deliverAs: "followUp")** — a single-shot
//       backup, only useful if (1) can't recognize the payload shape
//       (unknown provider). Falls through silently.
//
// The bash watcher (mithril-watch.sh) also recurs-SIGINTs PID 1 to break
// the agent out of long-running tool calls so a new LLM call fires.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { existsSync, readFileSync } from "node:fs";
import { dirname } from "node:path";

const SIG = process.env.MITHRIL_SIGNAL_FILE ?? "/opt/mithril/MITHRIL_SIGNAL.yml";
const ACK = process.env.SHUTDOWN_ACK_FILE ?? "/workspace/.shutdown-acked";
const POLL_MS = Number(process.env.MITHRIL_EXT_POLL_MS ?? 10_000);
// On non-Mithril hosts the signal directory is absent; entrypoint.sh skips
// the watcher under the same condition, so the extension follows suit.
const ENABLED = existsSync(dirname(SIG));

interface SignalState {
  status: string;
  endTime: string;
}

function readSignal(): SignalState | undefined {
  if (!existsSync(SIG)) return undefined;
  let text: string;
  try {
    text = readFileSync(SIG, "utf8");
  } catch {
    return undefined;
  }
  if (!/STATUS_(PREEMPTING|RELOCATING)/.test(text)) return undefined;
  const status = text.match(/^instance_status:\s*(.+)$/m)?.[1].trim() ?? "unknown";
  const endTime = text.match(/^end_time:\s*(.+)$/m)?.[1].trim() ?? "unknown";
  return { status, endTime };
}

// Shared with ops/mithril-hook.sh via mustache-style {{NAME}} placeholders.
const TEMPLATE_PATH = process.env.MITHRIL_NUDGE_TEMPLATE ?? "/usr/local/share/mithril-nudge.txt";
const FALLBACK_TEMPLATE =
  "MITHRIL SPOT INTERRUPTION SIGNALED ({{STATUS}}). Node terminates at {{END_TIME}}. " +
  "Commit + STATUS.md + ack + exit.";

function loadTemplate(): string {
  try {
    return readFileSync(TEMPLATE_PATH, "utf8");
  } catch {
    return FALLBACK_TEMPLATE;
  }
}

function buildNudge(s: SignalState): string {
  const homePath = process.env.HOME ?? "/home/ubuntu";
  return loadTemplate()
    .replaceAll("{{STATUS}}", s.status)
    .replaceAll("{{END_TIME}}", s.endTime)
    .replaceAll("{{HOME_PATH}}", homePath)
    .trim();
}

// Inject the nudge into an outgoing provider payload (Anthropic, OpenAI
// chat-completions/responses, or Gemini). Mutates `payload` in place. Returns
// true if injection succeeded. Unknown shapes log + skip; the queued
// sendUserMessage path below acts as a fallback in that case.
function injectIntoPayload(payload: unknown, nudge: string): boolean {
  if (!payload || typeof payload !== "object") return false;
  const p = payload as Record<string, unknown>;
  // Anthropic / OpenAI chat-completions: { messages: [{role, content}, ...] }
  if (Array.isArray(p.messages)) {
    (p.messages as unknown[]).push({ role: "user", content: nudge });
    return true;
  }
  // OpenAI Responses: { input: [{type, role, content: [{type, text}]}] }.
  // The top-level `type: "message"` is required by Azure's AI-Foundry
  // Responses schema (the public OpenAI endpoint infers it); omitting it
  // makes the injected nudge request 400 during a preemption.
  if (Array.isArray(p.input)) {
    (p.input as unknown[]).push({
      type: "message",
      role: "user",
      content: [{ type: "input_text", text: nudge }],
    });
    return true;
  }
  // Gemini: { contents: [{role, parts: [{text}]}] }
  if (Array.isArray(p.contents)) {
    (p.contents as unknown[]).push({ role: "user", parts: [{ text: nudge }] });
    return true;
  }
  return false;
}

export default function (pi: ExtensionAPI) {
  if (!ENABLED) return;
  let nudgedViaQueue = false;
  let timer: ReturnType<typeof setInterval> | undefined;

  // (1) Queued follow-up nudge as a backup. Single-shot per signal.
  const tick = () => {
    if (existsSync(ACK)) {
      nudgedViaQueue = false;
      return;
    }
    const sig = readSignal();
    if (!sig) {
      nudgedViaQueue = false;
      return;
    }
    if (nudgedViaQueue) return;
    nudgedViaQueue = true;
    try {
      pi.sendUserMessage(buildNudge(sig), { deliverAs: "followUp" });
    } catch (err) {
      process.stderr.write(`[mithril-ext] sendUserMessage failed: ${String(err)}\n`);
      nudgedViaQueue = false;
    }
  };

  // (2) Primary delivery path: inject the nudge into every outgoing provider
  // request while the signal is live and not yet acked. This guarantees the
  // agent sees the preemption notice on its very next LLM call (the next
  // assistant-turn boundary) rather than waiting for a follow-up message to
  // be drained from the queue — which doesn't happen when the agent is in a
  // long tool-call loop (bash → result → next bash → ...).
  pi.on("before_provider_request", (event) => {
    if (existsSync(ACK)) return;
    const sig = readSignal();
    if (!sig) return;
    const payload = (event as { payload?: unknown }).payload;
    const ok = injectIntoPayload(payload, buildNudge(sig));
    if (!ok) {
      process.stderr.write(
        "[mithril-ext] could not inject into provider payload (unknown shape); " +
          "falling back to queued followUp.\n",
      );
    }
  });

  pi.on("session_start", () => {
    if (timer) return;
    timer = setInterval(tick, POLL_MS);
    timer.unref?.();
  });

  pi.on("session_shutdown", () => {
    if (timer) {
      clearInterval(timer);
      timer = undefined;
    }
    nudgedViaQueue = false;
  });
}
