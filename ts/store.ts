import { QueueState } from "./types.ts";
import { emptyQueue, assertInvariants } from "./queue.ts";
import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export function queuePath(): string {
  const base =
    process.env.XDG_STATE_HOME ?? `${process.env.HOME}/.local/state`;
  return `${base}/omarchy/youn.yfocus/queue.json`;
}

/**
 * Queue locations used by earlier releases, newest first. Read once on
 * first access so an upgrade does not look like an empty queue.
 */
export function legacyQueuePaths(): string[] {
  const base =
    process.env.XDG_STATE_HOME ?? `${process.env.HOME}/.local/state`;
  return [
    `${base}/omarchy/yfocus/queue.json`,
    `${base}/omarchy/yfocus-queue/queue.json`,
  ];
}

async function maybeMigrateLegacy(): Promise<void> {
  const { copyFile, stat: stat2 } = await import("node:fs/promises");
  const newPath = queuePath();
  try {
    await stat2(newPath);
    return; // new exists
  } catch {}
  for (const oldPath of legacyQueuePaths()) {
    if (oldPath === newPath) continue;
    try {
      await stat2(oldPath);
    } catch {
      continue; // old missing
    }
    await ensureDir(newPath);
    try {
      await copyFile(oldPath, newPath);
    } catch {}
    return;
  }
}

async function ensureDir(path: string): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
}

// --- lock ------------------------------------------------------------
//
// Serialized mutations via an atomic mkdir lock. mkdir(2) fails with
// EEXIST when the directory already exists, which gives us a test-and-set
// without any race window. Stale locks (crashed writer) are broken after
// LOCK_STALE_MS based on the mtime of a marker file inside.

const LOCK_DIR = () => `${queuePath()}.lock`;
const LOCK_STALE_MS = 5000;
const LOCK_POLL_MS = 25;
const LOCK_TIMEOUT_MS = 4000;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function lockIsStale(): Promise<boolean> {
  try {
    const marker = `${LOCK_DIR()}/owner`;
    const info = await stat(marker);
    return Date.now() - info.mtimeMs > LOCK_STALE_MS;
  } catch {
    // No marker: treat empty lock dir as stale.
    return true;
  }
}

async function acquireLock(): Promise<void> {
  // mkdir(LOCK_DIR()) below is deliberately non-recursive -- EEXIST is the
  // test-and-set. That means the state directory has to exist first, which
  // it does not on a fresh install where nothing has read the queue yet.
  await ensureDir(LOCK_DIR());
  const deadline = Date.now() + LOCK_TIMEOUT_MS;
  for (;;) {
    try {
      await mkdir(LOCK_DIR());
      await writeFile(`${LOCK_DIR()}/owner`, `${process.pid}@${Date.now()}`);
      return;
    } catch (err: any) {
      if (err && err.code !== "EEXIST") throw err;
      if (Date.now() > deadline) {
        if (await lockIsStale()) {
          await rm(LOCK_DIR(), { recursive: true, force: true });
          continue; // one more attempt with the stale lock cleared
        }
        throw new Error("yfocus: could not acquire queue lock");
      }
      await sleep(LOCK_POLL_MS);
    }
  }
}

async function releaseLock(): Promise<void> {
  await rm(LOCK_DIR(), { recursive: true, force: true });
}

// --- read/write ------------------------------------------------------

/**
 * Read the queue from disk. Missing or empty file initializes an empty
 * queue on disk. Corrupt JSON or violated invariants throw so the caller
 * can surface a clean error instead of silently destroying data.
 */
export async function readQueue(path: string = queuePath()): Promise<QueueState> {
  if (path === queuePath()) await maybeMigrateLegacy();
  await ensureDir(path);
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch (err: any) {
    if (err && err.code === "ENOENT") {
      const empty = emptyQueue();
      await writeQueue(empty, path);
      return empty;
    }
    throw err;
  }
  if (text.trim().length === 0) {
    const empty = emptyQueue();
    await writeQueue(empty, path);
    return empty;
  }
  const parsed = JSON.parse(text) as QueueState;
  assertInvariants(parsed);
  return parsed;
}

/**
 * Atomically write the queue: temp file, fsync, rename over target.
 * Rename is atomic on POSIX when both paths are on one filesystem.
 */
export async function writeQueue(
  state: QueueState,
  path: string = queuePath(),
): Promise<void> {
  if (path === queuePath()) await maybeMigrateLegacy();
  assertInvariants(state);
  await ensureDir(path);
  const tmp = `${path}.tmp.${process.pid}.${Date.now()}`;
  const handle = await import("node:fs/promises").then((m) => m.open(tmp, "w"));
  try {
    await handle.writeFile(JSON.stringify(state, null, 2) + "\n");
    await handle.sync();
  } finally {
    await handle.close();
  }
  await rename(tmp, path);
}

/**
 * Read-modify-write under the lock. `fn` returns the next state (or the
 * same reference for a no-op, which skips the write).
 */
export async function mutate<T>(
  fn: (state: QueueState) => { state: QueueState; result?: T },
  path: string = queuePath(),
): Promise<{ state: QueueState; result?: T }> {
  await acquireLock();
  try {
    const current = await readQueue(path);
    const { state: next, result } = fn(current);
    if (next === current) return { state: current, result };
    await writeQueue(next, path);
    return { state: next, result };
  } finally {
    await releaseLock();
  }
}
