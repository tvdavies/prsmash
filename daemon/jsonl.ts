// Strict JSONL framing for pi's RPC mode: records end at LF only. Node's
// readline also splits on U+2028/U+2029, which are legal inside JSON strings,
// so it must not be used here (pi docs/rpc.md, "Framing").

import type { Readable } from "node:stream";

export function readJsonl(stream: Readable, onRecord: (record: unknown) => void, onBadLine?: (line: string) => void): void {
  let buffer = "";
  stream.setEncoding("utf8");
  stream.on("data", (chunk: string) => {
    buffer += chunk;
    let newline = buffer.indexOf("\n");
    while (newline !== -1) {
      let line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (line.endsWith("\r")) line = line.slice(0, -1);
      if (line.length > 0) {
        try {
          onRecord(JSON.parse(line));
        } catch {
          onBadLine?.(line);
        }
      }
      newline = buffer.indexOf("\n");
    }
  });
}
