// Tests of the WASI reference host's components: `node wasmtime.test.mjs WASMTIME
// JCO world.wit canceller.wat app.wasm app_queue.wasm app_crash.wasm
// app_forever.wasm`, the apps beside this file built for wasm32. jco makes each a
// component, which wasmtime runs with WASI 0.3.0 and no other experimental
// feature.

import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import test, { after } from "node:test";
import { promisify } from "node:util";

const [wasmtime, jco, world, cancellerPath, ...modules] = process.argv.slice(2);
const directory = await mkdtemp(join(tmpdir(), "roc-wasi-tasks-"));
after(() => rm(directory, { recursive: true }));

const call = promisify(execFile);

const [app, queue, crash, forever] = await Promise.all(
  modules.map(async (module) => {
    const name = join(directory, basename(module, ".wasm"));
    await call(jco, ["embed", module, "--wit", world, "--world-name", "app", "-o", `${name}.embedded.wasm`]);
    await call(jco, ["new", `${name}.embedded.wasm`, "-o", `${name}.component.wasm`]);
    return `${name}.component.wasm`;
  }),
);

const command = ["run", "-W", "component-model-async=y", "-S", "p3=y,cli=y"];

/** How a run of a component ended, or what `read` makes of it as it runs. */
function run(component, read = () => {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(wasmtime, [...command, component]);
    const outcome = { code: null, stdout: "", stderr: "" };
    child.stdout.on("data", (data) => (outcome.stdout += data));
    child.stderr.on("data", (data) => (outcome.stderr += data));
    child.on("error", reject);
    child.on("close", (code) => resolve({ ...outcome, code }));
    read(child);
  });
}

const slept = "slept 0\nslept 1\nslept 45\nslept 90\n0 1 45 90 early 136\n";
const took = [0, 1, 2, 3].map((i) => `took item ${i}, too long to be stored inline\n`).join("");

test("tasks sleep at the same time, and a race abandons the timer that lost", async () => {
  assert.deepEqual(await run(app), { code: 0, stdout: slept, stderr: "" });
});

test("a program whose output nothing reads runs to its end", async () => {
  const { code, stderr } = await run(app, (child) => child.stdout.destroy());
  // Whether the error is the program's failure is up to the stream's reader.
  assert.ok(code === 0 || code === 1);
  assert.equal(stderr, "");
});

test("tasks wait for each other's updates of shared state, and Err is the program's failure", async () => {
  const { code, stdout, stderr } = await run(queue);
  assert.deepEqual([code, stderr], [1, "the queue is closed, and nothing more will come\n"]);
  assert.equal(stdout.replace("producer is done\n", ""), `${took}consumer is done\n`);
});

test("a crash traps, with its message on the error stream", async () => {
  const { code, stdout, stderr } = await run(crash);
  assert.equal(stdout, "before the crash\n");
  assert.ok(stderr.startsWith("the app crashed\n"));
  assert.notEqual(code, 0);
});

test("a caller cancels run, and a second call waits until the first is over", async () => {
  const { stdout: text } = await call(jco, ["print", forever], { maxBuffer: 1 << 28 });
  const canceller = await readFile(cancellerPath, "utf8");
  const nested = text.replace("(component", "(component $app");
  const path = join(directory, "canceller.wat");
  await writeFile(
    path,
    canceller.replace("(component $app)", () => nested),
  );
  assert.deepEqual(await run(path), { code: 0, stdout: "running\nrunning too\n".repeat(2), stderr: "" });
});
