// The browser reference host's scheduler (design.md "Host Contract",
// "Browser hosts."), for any JavaScript event loop.
//
// A ready task goes on a queue, which a microtask empties. A suspending hosted
// function starts a promise and returns pending, and the promise's end writes
// the result and wakes the task. So Roc code runs only from that microtask, on
// one thread, and never inside a hosted call.

const PENDING = 0;
const DONE = 1;
const CANCELLED = 2;

const decoder = new TextDecoder();
const encoder = new TextEncoder();

/**
 * Run a program built for the platform in `platform/`. The promise resolves to
 * `{ status: "done", result, liveAllocations }`, or
 * `{ status: "cancelled", liveAllocations }` once `signal` cancelled it, and
 * rejects with what the program crashed with.
 *
 * @param {WebAssembly.Module} module
 * @param {{ fetchText?: (url: string, signal: AbortSignal) => Promise<string>, log?: (line: string) => void, signal?: AbortSignal }} [options]
 */
export async function run(module, options = {}) {
  const { fetchText = fetchPage, log = console.log, signal } = options;
  let exports;
  /** The tasks to resume, in the order they became ready. */
  const ready = [];
  let draining = false;
  /** The end of each operation in progress, by the task that waits on it. */
  const operations = new Map();
  let crash = null;
  let finish;
  let fail;
  const ended = new Promise((resolve, reject) => {
    finish = resolve;
    fail = reject;
  });
  let root = 0;

  const text = (address, length) => decoder.decode(new Uint8Array(exports.memory.buffer, address >>> 0, length >>> 0));

  /** Copy text into the module's memory, for an export that takes it over. */
  const copyIn = (string) => {
    const bytes = encoder.encode(string);
    const address = exports.host_alloc(bytes.length) >>> 0;
    new Uint8Array(exports.memory.buffer, address, bytes.length).set(bytes);
    return [address, bytes.length];
  };

  /** Call into the module from the event loop. A crash there ends the run. */
  const enter = (call) => {
    if (crash !== null) return;
    try {
      call();
    } catch (error) {
      crash = error;
      for (const abandon of operations.values()) abandon();
      operations.clear();
      fail(error);
    }
  };

  const drain = () =>
    enter(() => {
      draining = true;
      while (ready.length > 0) {
        const task = ready.shift();
        const status = exports.host_resume(task);
        if (task === root && status !== PENDING) end(status);
      }
      draining = false;
    });

  const end = (status) => {
    let outcome;
    if (status === DONE) {
      const packed = exports.host_result();
      outcome = { status: "done", result: text(Number(packed >> 32n), Number(packed & 0xffffffffn)) };
      exports.host_release_result();
    } else if (status === CANCELLED) {
      outcome = { status: "cancelled" };
    } else {
      // wasm has no crash exit, so no task reports a crash.
      throw new Error(`the root task reported status ${status}`);
    }
    exports.host_free(root);
    signal?.removeEventListener("abort", cancel);
    finish({ ...outcome, liveAllocations: exports.host_live_allocations() });
  };

  const cancel = () => enter(() => exports.host_cancel(root));

  /** The operation `task` waits on ended, unless it was abandoned. */
  const complete = (task, abandon, wake) => {
    if (operations.get(task) !== abandon) return;
    operations.delete(task);
    enter(wake);
  };

  const env = {
    js_ready(task) {
      ready.push(task);
      // A resume that is running is already followed by the rest of the queue.
      if (!draining && ready.length === 1) queueMicrotask(drain);
    },
    js_abort(task) {
      const abandon = operations.get(task);
      operations.delete(task);
      abandon?.();
    },
    js_sleep(task, millis) {
      const timer = setTimeout(() => complete(task, abandon, () => exports.host_wake(task)), millis);
      const abandon = () => clearTimeout(timer);
      operations.set(task, abandon);
    },
    js_get(task, out, address, length) {
      const controller = new AbortController();
      const abandon = () => controller.abort();
      operations.set(task, abandon);
      const wake = (string, failed) =>
        complete(task, abandon, () => {
          const [copied, size] = copyIn(string);
          exports.host_wake_get(task, out, copied, size, failed);
        });
      const url = text(address, length);
      Promise.resolve()
        .then(() => fetchText(url, controller.signal))
        .then(
          (page) => wake(page, 0),
          (error) => wake(String(error?.message ?? error), 1),
        );
    },
    js_log(address, length) {
      log(text(address, length));
    },
    js_dbg(address, length) {
      console.debug(text(address, length));
    },
    js_expect_failed(address, length) {
      console.error(text(address, length));
    },
    js_crashed(address, length) {
      throw new Error(text(address, length));
    },
  };

  ({ exports } = await WebAssembly.instantiate(module, { env }));
  enter(() => {
    root = exports.host_start();
    if (signal?.aborted) exports.host_cancel(root);
    else signal?.addEventListener("abort", cancel);
    env.js_ready(root);
  });
  return ended;
}

async function fetchPage(url, signal) {
  const response = await fetch(url, { signal });
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
  return response.text();
}
