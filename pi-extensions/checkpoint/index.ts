// Periodic self-nudge for autonomous runs: every ~30 min the agent gets a
// user message reminding it to refresh /workspace/STATUS.md and commit
// substantive changes. The nudge embeds a fresh GPU/disk snapshot so the
// agent has something concrete to record in STATUS.md without first
// shelling out to nvidia-smi / df itself.
//
// Single timer per session; cleared on session_shutdown. Skipped if
// /workspace is not present (non-autonomous host).

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { existsSync } from "node:fs";
import { getResourceSnapshot } from "../_shared/resources.js";

const INTERVAL_MS = Number(process.env.CHECKPOINT_INTERVAL_MS ?? 30 * 60 * 1000);
const DISK_PATH = process.env.CHECKPOINT_DISK_PATH ?? "/workspace";
const ENABLED = existsSync(DISK_PATH);

function buildNudge(snapshot: string): string {
  const minutes = Math.round(INTERVAL_MS / 60_000);
  return (
    `Checkpoint reminder (~${minutes}min cadence).\n` +
    `Resources:\n${snapshot}\n\n` +
    `If substantive progress since the last commit/STATUS update: refresh ` +
    `/workspace/STATUS.md to reflect current state, then ` +
    `\`cd /workspace && git add -A && git commit -m "..."\`. ` +
    `If nothing material has changed, no action needed — just acknowledge briefly and continue.`
  );
}

export default function (pi: ExtensionAPI) {
  if (!ENABLED) return;
  let timer: ReturnType<typeof setInterval> | undefined;

  const tick = async () => {
    let snapshot: string;
    try {
      snapshot = await getResourceSnapshot(DISK_PATH);
    } catch (err) {
      snapshot = `resources: unavailable (${String(err)})`;
    }
    try {
      pi.sendUserMessage(buildNudge(snapshot), { deliverAs: "followUp" });
    } catch (err) {
      process.stderr.write(`[checkpoint] sendUserMessage failed: ${String(err)}\n`);
    }
  };

  pi.on("session_start", () => {
    if (timer) return;
    timer = setInterval(tick, INTERVAL_MS);
    timer.unref?.();
  });

  pi.on("session_shutdown", () => {
    if (timer) {
      clearInterval(timer);
      timer = undefined;
    }
  });
}
