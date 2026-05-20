// `resources` tool: on-demand GPU + disk snapshot.
//
// The same snapshot is embedded in the checkpoint nudge, but the agent
// often wants to self-diagnose mid-task ("is the training step hung?",
// "is disk filling up?") without calling out to bash. Exposing this as a
// named tool also surfaces the capability in the system prompt.

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { getResourceSnapshot } from "../_shared/resources.js";

const DISK_PATH = process.env.RESOURCES_DISK_PATH ?? "/workspace";

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "resources",
    label: "Resources snapshot",
    description:
      "Show current GPU utilization (nvidia-smi) and disk usage (df -h) for /workspace. " +
      "No arguments. Use to self-diagnose stuck training, OOM, or disk pressure without shelling out.",
    parameters: Type.Object({}),
    promptSnippet: "Use `resources` to check GPU/disk state.",
    execute: async () => {
      const text = await getResourceSnapshot(DISK_PATH);
      return {
        content: [{ type: "text", text }],
        details: {},
      };
    },
  });
}
