// A stand-in for a component runtime, so that the WASI reference host's tests
// need nothing but Node: the canonical built-ins platform/host.zig imports, and
// the loop that calls the callback of an async-lifted function. A misuse the
// component model traps on throws.

const decoder = new TextDecoder();

const BLOCKED = 0xffffffff | 0;
const EXIT = 0;
const WAIT = 2;
const EVENT = { subtask: 1, streamWrite: 3, futureRead: 4, taskCancelled: 6 };
const STARTED = 1;
const RETURNED = 2;
const CANCELLED_BEFORE_RETURNED = 4;
const DROPPED = 1;

function trapIf(condition, why) {
  if (condition) throw new Error(`component model trap: ${why}`);
}

/**
 * Instantiate a core module and call `wasi:cli/run`. The promise resolves to how
 * that went, `{ status, stdout, stderr, timers }`: `status` is "ok", "err",
 * "cancelled", or the error a trap threw, and `timers` what became of each timer.
 *
 * `chunk`: how many bytes the reader of the output stream takes at a time, each
 * on a later turn. Without it, it takes each write at once. `closeAfter`: the
 * reader goes away once it has taken this many bytes. `cancel`: a promise after
 * which the caller cancels `run`.
 *
 * @param {WebAssembly.Module} module
 * @param {{ chunk?: number, closeAfter?: number, cancel?: Promise<void> }} [options]
 */
export async function run(module, { chunk = 0, closeAfter = Infinity, cancel } = {}) {
  const handles = new Map();
  let lastHandle = 0;
  let exports;
  let outcome = null;
  let backpressure = 0;
  let cancelDelivered = false;
  let wakeLoop = () => {};
  const text = { stdout: "", stderr: "" };
  const timers = [];

  const add = (kind, fields) => {
    lastHandle += 1;
    handles.set(lastHandle, { kind, handle: lastHandle, set: 0, event: null, ...fields });
    return lastHandle;
  };
  const get = (handle, kind) => {
    const found = handles.get(handle);
    trapIf(found?.kind !== kind, `handle ${handle} is no ${kind}`);
    return found;
  };
  const drop = (handle, kind) => {
    const found = get(handle, kind);
    trapIf(found.event !== null, `a ${kind} is dropped with an event`);
    trapIf(found.busy === true, `a ${kind} is dropped in use`);
    handles.delete(handle);
  };
  const post = (waitable, event) => {
    waitable.event = event;
    wakeLoop();
  };
  const bytes = (address, length) => new Uint8Array(exports.memory.buffer, address >>> 0, length >>> 0);

  const outputInterface = (name) => {
    const taken = [];
    let count = 0;
    let closed = () => {};
    const take = (address, length) => {
      const size = Math.min(length, closeAfter - count);
      taken.push(...bytes(address, size));
      count += size;
      text[name] = decoder.decode(Uint8Array.from(taken));
      return (size << 4) | (size < length || count >= closeAfter ? DROPPED : 0);
    };
    const stream = (handle) => {
      const writable = get(handle, "writable");
      trapIf(writable.busy, "a stream is written while it is being written");
      return writable;
    };
    const finish = (future, address) => {
      bytes(address, 1)[0] = 0;
      future.busy = false;
    };
    return {
      "write-via-stream": (readable) => {
        drop(readable, "readable");
        return add("future", { done: new Promise((resolve) => (closed = resolve)), busy: false });
      },
      "[stream-new-0]write-via-stream": () => {
        const readable = add("readable", {});
        const writable = add("writable", { busy: false });
        return (BigInt(writable) << 32n) | BigInt(readable);
      },
      "[async-lower][stream-write-0]write-via-stream": (handle, address, length) => {
        const writable = stream(handle);
        if (chunk === 0 || name === "stderr" || count >= closeAfter) return take(address, length);
        writable.busy = true;
        setTimeout(() => {
          writable.busy = false;
          post(writable, [EVENT.streamWrite, handle, take(address, Math.min(chunk, length))]);
        }, 0);
        return BLOCKED;
      },
      "[stream-drop-writable-0]write-via-stream": (handle) => {
        drop(handle, "writable");
        closed();
      },
      "[async-lower][future-read-1]write-via-stream": (handle, address) => {
        const future = get(handle, "future");
        trapIf(future.busy, "a future is read while it is being read");
        if (name === "stderr") {
          finish(future, address);
          return 0;
        }
        future.busy = true;
        future.done.then(() => {
          finish(future, address);
          post(future, [EVENT.futureRead, handle, 0]);
        });
        return BLOCKED;
      },
      "[future-drop-readable-1]write-via-stream": (handle) => drop(handle, "future"),
    };
  };

  const imports = {
    $root: {
      "[waitable-set-new]": () => add("set", {}),
      // Nothing here can block, so nothing the host blocks on is left to wait for.
      "[waitable-set-wait]": () => trapIf(true, "a wait that blocks"),
      "[waitable-set-drop]": (set) => {
        for (const waitable of handles.values()) trapIf(waitable.set === set, "a set is dropped with members");
        drop(set, "set");
      },
      "[waitable-join]": (waitable, set) => {
        if (set !== 0) get(set, "set");
        handles.get(waitable).set = set;
      },
      "[subtask-drop]": (handle) => {
        trapIf(!get(handle, "subtask").delivered, "a subtask is dropped before it resolved");
        drop(handle, "subtask");
      },
      "[subtask-cancel]": (handle) => {
        const subtask = get(handle, "subtask");
        trapIf(subtask.delivered, "a resolved subtask is cancelled");
        trapIf(subtask.set !== 0, "a subtask in a set is cancelled synchronously");
        if (subtask.event !== null) {
          const [, , state] = subtask.event;
          subtask.event = null;
          subtask.delivered = true;
          return state;
        }
        clearTimeout(subtask.timeout);
        timers[subtask.index] = "cancelled";
        subtask.delivered = true;
        return CANCELLED_BEFORE_RETURNED;
      },
      "[backpressure-inc]": () => {
        backpressure += 1;
      },
      "[backpressure-dec]": () => {
        trapIf(backpressure === 0, "no backpressure to take back");
        backpressure -= 1;
      },
    },
    "[export]$root": {
      "[task-cancel]": () => {
        trapIf(!cancelDelivered, "a task is cancelled that was not asked to be");
        trapIf(outcome !== null, "a task returns twice");
        outcome = "cancelled";
      },
    },
    "[export]wasi:cli/run@0.3.0": {
      "[task-return]run": (failed) => {
        trapIf(outcome !== null, "a task returns twice");
        outcome = failed ? "err" : "ok";
      },
    },
    "wasi:clocks/monotonic-clock@0.3.0": {
      "[async-lower]wait-for": (nanoseconds) => {
        if (nanoseconds === 0n) return RETURNED;
        const index = timers.push("running") - 1;
        const handle = add("subtask", { index, delivered: false });
        const subtask = handles.get(handle);
        subtask.timeout = setTimeout(
          () => {
            timers[index] = "returned";
            post(subtask, [EVENT.subtask, handle, RETURNED]);
          },
          Number(nanoseconds) / 1e6,
        );
        return (handle << 4) | STARTED;
      },
    },
    "wasi:cli/stdout@0.3.0": outputInterface("stdout"),
    "wasi:cli/stderr@0.3.0": outputInterface("stderr"),
  };

  let cancelRequested = false;
  cancel?.then(() => {
    cancelRequested = true;
    wakeLoop();
  });

  /** The next event of a set, waiting for one. */
  const nextEvent = async (set) => {
    for (;;) {
      if (cancelRequested && !cancelDelivered) {
        cancelDelivered = true;
        return [EVENT.taskCancelled, 0, 0];
      }
      for (const waitable of handles.values()) {
        if (waitable.set === set && waitable.event !== null) {
          const event = waitable.event;
          waitable.event = null;
          if (event[0] === EVENT.subtask) waitable.delivered = true;
          return event;
        }
      }
      await new Promise((resolve) => (wakeLoop = resolve));
    }
  };

  ({ exports } = await WebAssembly.instantiate(module, imports));
  const end = (status) => ({ status, ...text, timers });
  try {
    let code = exports["[async-lift]wasi:cli/run@0.3.0#run"]();
    while ((code & 0xf) !== EXIT) {
      trapIf((code & 0xf) !== WAIT, `callback code ${code & 0xf}`);
      code = exports["[callback][async-lift]wasi:cli/run@0.3.0#run"](...(await nextEvent(code >>> 4)));
    }
    trapIf(outcome === null, "a task exits without returning");
    trapIf(backpressure !== 0, "a task exits with its backpressure on");
    trapIf(handles.size !== 0, `a task exits with ${[...handles.values()].map(({ kind }) => kind)} not dropped`);
  } catch (error) {
    for (const { timeout } of handles.values()) clearTimeout(timeout);
    return end(error);
  }
  return end(outcome);
}
