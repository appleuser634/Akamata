// A single WebAssembly instance is not reentrant while an exported call is
// suspended by JSPI. Keep the complete request/response ABI transaction under
// one FIFO lock: allocation, handle_fetch, response metadata/copy, and frees.
export class WasmDispatchQueue {
  #tail = Promise.resolve();

  async run(dispatch) {
    let release;
    const previous = this.#tail;
    this.#tail = new Promise((resolve) => { release = resolve; });
    await previous;
    try {
      return await dispatch();
    } finally {
      release();
    }
  }
}
