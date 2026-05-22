// pi-side counterpart to ops/mithril-hook.sh.
//
// Claude Code learns about Mithril spot preemption via a PreToolUse hook
// (ops/claude-settings.json + ops/mithril-hook.sh) that injects
// additionalContext into the next tool call. pi has no equivalent hook
// mechanism, so when pi profiles are used the watcher still SIGINTs PID 1
// (handled by mithril-watch.sh) but the agent gets no explanatory message.
//
// This extension polls the same signal file the bash hook reads. On the
// first preemption signal (until /workspace/.shutdown-acked appears) it
// injects a user message via pi.sendUserMessage so the agent sees the
// same instructions Claude does: commit, write STATUS.md, ack, exit.
//
// Single-shot per signal: once the message has been sent we wait for the
// agent to ack (touch the ack file) or for the signal to clear before
// re-arming. This avoids spamming during the typically-minutes-long
// preemption window — the watcher's recurring SIGINT handles "wake up
// from the current tool call", this just provides the context.

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
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

export default function (pi: ExtensionAPI) {
  if (!ENABLED) return;
  let nudged = false;
  let timer: ReturnType<typeof setInterval> | undefined;

  const tick = () => {
    if (existsSync(ACK)) {
      nudged = false;
      return;
    }
    const sig = readSignal();
    if (!sig) {
      nudged = false;
      return;
    }
    if (nudged) return;
    nudged = true;
    try {
      pi.sendUserMessage(buildNudge(sig), { deliverAs: "followUp" });
    } catch (err) {
      process.stderr.write(`[mithril-ext] sendUserMessage failed: ${String(err)}\n`);
      nudged = false;
    }
  };

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
    nudged = false;
  });
}
