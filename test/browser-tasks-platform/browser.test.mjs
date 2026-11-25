// Tests of the browser reference host: `node browser.test.mjs app.wasm
// app_queue.wasm app_crash.wasm`, the apps beside this file built for wasm32.
// Node's event loop stands in for a browser's.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { run } from "./host.mjs";

const [app, queue, crash] = await Promise.all(process.argv.slice(2).map(async (path) => WebAssembly.compile(await readFile(path))));

/** Answers `/slow` after `/quick`, and fails for `/missing`. */
function pages(requests = []) {
  let releaseSlow;
  const slow = new Promise((resolve) => {
    releaseSlow = resolve;
  });
  return (url, signal) => {
    requests.push({ url, signal });
    if (url === "/quick") {
      setTimeout(() => releaseSlow("the slow page, too long to be stored inline"), 1);
      return Promise.resolve("the quick page");
    }
    if (url === "/slow") return slow;
    return Promise.reject(new Error("404"));
  };
}

const answer = "the quick page none the slow page, too long to be stored inline early 57";

test("tasks fetch at the same time, and a loop takes their results as they arrive", async () => {
  const lines = [];
  const outcome = await run(app, { fetchText: pages(), log: (line) => lines.push(line) });
  assert.deepEqual(lines, ["/quick: the quick page", "/missing failed: 404", "/slow: the slow page, too long to be stored inline"]);
  assert.deepEqual(outcome, { status: "done", result: answer, liveAllocations: 0 });
});

test("two runs on one event loop share nothing", async () => {
  const outcomes = await Promise.all([run(app, { fetchText: pages(), log() {} }), run(app, { fetchText: pages(), log() {} })]);
  for (const outcome of outcomes) assert.deepEqual(outcome, { status: "done", result: answer, liveAllocations: 0 });
});

test("a run's end abandons the timer a race lost, so nothing keeps the event loop waiting", async () => {
  const started = performance.now();
  await run(app, { fetchText: pages(), log() {} });
  assert.ok(performance.now() - started < 4000);
});

test("cancelling a run aborts its requests and frees everything", async () => {
  const requests = [];
  const controller = new AbortController();
  const outcome = run(app, {
    fetchText: (url, signal) => {
      requests.push({ url, signal });
      return new Promise((_, reject) => signal.addEventListener("abort", () => reject(new Error("aborted"))));
    },
    log: () => assert.fail("a cancelled task logged"),
    signal: controller.signal,
  });
  setTimeout(() => controller.abort(), 1);
  assert.deepEqual(await outcome, { status: "cancelled", liveAllocations: 0 });
  assert.deepEqual(
    requests.map(({ url, signal }) => [url, signal.aborted]),
    [
      ["/slow", true],
      ["/quick", true],
      ["/missing", true],
    ],
  );
});

test("a run cancelled before it begins runs no code", async () => {
  const outcome = await run(app, { fetchText: () => assert.fail("fetched"), signal: AbortSignal.abort() });
  assert.deepEqual(outcome, { status: "cancelled", liveAllocations: 0 });
});

test("tasks wait for each other's updates of shared state", async () => {
  const outcome = await run(queue, { log() {} });
  assert.deepEqual(outcome, { status: "done", result: "producer consumer item 0, item 1, item 2, item 3", liveAllocations: 0 });
});

test("a crash rejects the run with its message", async () => {
  await assert.rejects(run(crash), { message: "the app crashed" });
});
