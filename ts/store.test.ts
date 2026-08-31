import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { add } from "./queue.ts";
import { mutate, queuePath, readQueue } from "./store.ts";

const ORIGINAL_STATE_HOME = process.env.XDG_STATE_HOME;
const temps: string[] = [];

async function freshStateHome(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "yfocus-store-"));
  temps.push(dir);
  process.env.XDG_STATE_HOME = dir;
  return dir;
}

afterEach(async () => {
  if (ORIGINAL_STATE_HOME === undefined) delete process.env.XDG_STATE_HOME;
  else process.env.XDG_STATE_HOME = ORIGINAL_STATE_HOME;
  await Promise.all(temps.splice(0).map((d) => rm(d, { recursive: true, force: true })));
});

describe("fresh install", () => {
  test("mutate creates the state directory instead of failing on the lock", async () => {
    await freshStateHome();
    const { state } = await mutate((s) => ({ state: add(s, "first task", "") }));
    expect(state.tasks).toHaveLength(1);
    expect(state.current).toBe(state.tasks[0].id);
    expect(await readQueue()).toEqual(state);
  });
});

describe("legacy migration", () => {
  const seeded = {
    version: 1 as const,
    current: "a",
    tasks: [
      {
        id: "a",
        title: "carried over",
        note: "",
        position: 0,
        createdAt: 1,
        startedAt: 1,
        doneAt: null,
      },
    ],
  };

  for (const legacy of ["yfocus", "yfocus-queue"]) {
    test(`adopts a queue left in omarchy/${legacy}`, async () => {
      const home = await freshStateHome();
      await mkdir(join(home, "omarchy", legacy), { recursive: true });
      await writeFile(join(home, "omarchy", legacy, "queue.json"), JSON.stringify(seeded));

      expect(await readQueue()).toEqual(seeded);
      expect(queuePath()).toBe(join(home, "omarchy", "youn.yfocus", "queue.json"));
    });
  }

  test("leaves an existing queue alone", async () => {
    const home = await freshStateHome();
    await mkdir(join(home, "omarchy", "yfocus"), { recursive: true });
    await writeFile(join(home, "omarchy", "yfocus", "queue.json"), JSON.stringify(seeded));
    await mkdir(join(home, "omarchy", "youn.yfocus"), { recursive: true });
    await writeFile(queuePath(), JSON.stringify({ version: 1, current: null, tasks: [] }));

    expect((await readQueue()).tasks).toHaveLength(0);
  });
});
