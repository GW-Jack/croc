// Tests of the WASI reference host's core module: `node module.test.mjs app.wasm
// app_queue.wasm app_crash.wasm app_forever.wasm`, the apps beside this file
// built for wasm32. component.mjs stands in for a component runtime.
// wasmtime.test.mjs has the tests of the components on a real one.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { run } from "./component.mjs";

const [app, queue, crash, forever] = await Promise.all(process.argv.slice(2).map(async (path) => WebAssembly.compile(await readFile(path))));

const slept = "slept 0\nslept 1\nslept 45\nslept 90\n0 1 45 90 early 136\n";
const took = [0, 1, 2, 3].map((i) => `took item ${i}, too long to be stored inline\n`).join("");

test("tasks sleep at the same time, and a race abandons the timer that lost", async () => {
  const outcome = await run(app);
  assert.deepEqual(outcome, {
    status: "ok",
    stdout: slept,
    stderr: "",
    timers: ["returned", "returned", "returned", "cancelled", "returned"],
  });
});

test("lines come out whole and in order through a reader that takes a few bytes at a time", async () => {
  const { status, stdout } = await run(app, { chunk: 3 });
  assert.deepEqual([status, stdout.split("\n").toSorted()], ["ok", slept.split("\n").toSorted()]);
});

test("a program whose output nothing reads runs to its end", async () => {
  for (const options of [{ closeAfter: 0 }, { closeAfter: 5 }, { closeAfter: 5, chunk: 3 }]) {
    const { status, stdout } = await run(app, options);
    assert.deepEqual([status, stdout.length], ["ok", options.closeAfter]);
  }
});

test("tasks wait for each other's updates of shared state, and Err is the program's failure", async () => {
  for (const options of [{}, { chunk: 7 }]) {
    const { status, stdout, stderr } = await run(queue, options);
    assert.deepEqual([status, stderr], ["err", "the queue is closed, and nothing more will come\n"]);
    assert.equal(stdout.replace("producer is done\n", ""), `${took}consumer is done\n`);
  }
});

test("a crash traps, with its message on the error stream", async () => {
  const { status, stdout, stderr } = await run(crash);
  assert.ok(status instanceof WebAssembly.RuntimeError);
  assert.deepEqual([stdout, stderr], ["before the crash\n", "the app crashed\n"]);
});

test("cancelling run cancels its timers and frees everything", async () => {
  // Cancel once every task is waiting: three on their timers, one on shared
  // state. A fixed delay raced the reader on hosts with coarse timers, where the
  // last task's line was still being taken one byte a turn when it ran out.
  const waiting = ({ timers }) => timers.length === 3;
  for (const options of [{}, { chunk: 1 }]) {
    const { status, stdout, stderr, timers } = await run(forever, { ...options, cancelWhen: waiting });
    assert.deepEqual([status, stdout, stderr, timers], ["cancelled", "running\nrunning too\n", "", ["cancelled", "cancelled", "cancelled"]]);
  }
});

test("a line that is begun when its task is cancelled is written whole, and one that is not is dropped", async () => {
  const { status, stdout } = await run(forever, { chunk: 1, cancel: Promise.resolve() });
  assert.deepEqual([status, stdout], ["cancelled", "running\n"]);
});

test("run cancelled before it waits prints what it had already printed", async () => {
  const { status, timers } = await run(forever, { cancel: Promise.resolve() });
  assert.deepEqual([status, timers.includes("running")], ["cancelled", false]);
});
