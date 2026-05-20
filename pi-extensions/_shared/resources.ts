// Compact GPU + disk snapshot for the checkpoint nudge and the `resources`
// tool. Shells out to nvidia-smi and df with short timeouts; on failure
// returns a one-line "unavailable: ..." so callers can still surface
// something useful instead of throwing.

import { execFile } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execFile);
const EXEC_TIMEOUT_MS = 5_000;

export async function getGpuSnapshot(): Promise<string> {
  try {
    const { stdout } = await exec(
      "nvidia-smi",
      [
        "--query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu",
        "--format=csv,noheader,nounits",
      ],
      { timeout: EXEC_TIMEOUT_MS },
    );
    const lines = stdout.trim().split("\n").filter(Boolean);
    if (lines.length === 0) return "gpu: none detected";
    return lines
      .map((line) => {
        const [idx, util, used, total, temp] = line.split(",").map((s) => s.trim());
        return `gpu${idx}: ${util}% util, ${used}/${total} MiB, ${temp}°C`;
      })
      .join("; ");
  } catch (err) {
    return `gpu: unavailable (${(err as Error).message.split("\n")[0]})`;
  }
}

export async function getDiskSnapshot(path = "/workspace"): Promise<string> {
  try {
    const { stdout } = await exec(
      "df",
      ["-h", "--output=size,used,avail,pcent", path],
      { timeout: EXEC_TIMEOUT_MS },
    );
    const lines = stdout.trim().split("\n");
    if (lines.length < 2) return `disk(${path}): unavailable`;
    const [, used, avail, pcent] = lines[1].trim().split(/\s+/);
    return `disk(${path}): ${used} used / ${avail} avail (${pcent})`;
  } catch (err) {
    return `disk(${path}): unavailable (${(err as Error).message.split("\n")[0]})`;
  }
}

export async function getResourceSnapshot(diskPath = "/workspace"): Promise<string> {
  const [gpu, disk] = await Promise.all([getGpuSnapshot(), getDiskSnapshot(diskPath)]);
  return `${gpu}\n${disk}`;
}
