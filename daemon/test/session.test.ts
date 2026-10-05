import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync, existsSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const sessionBin = resolve(here, "../../bin/prsmash-session");
const fakePi = resolve(here, "fake-pi.mjs");

function git(cwd: string, ...args: string[]): string {
  return execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
}

function commit(repo: string, file: string, content: string, message: string): string {
  writeFileSync(join(repo, file), content);
  git(repo, "add", file);
  git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message);
  return git(repo, "rev-parse", "HEAD");
}

// A bare "origin" with refs/pull/1/head, an author clone that pushes to it,
// and a review worktree checked out at the first head.
function fixture() {
  const root = mkdtempSync(join(tmpdir(), "prsmash-session-"));
  const origin = join(root, "origin.git");
  const author = join(root, "author");
  const worktree = join(root, "worktree");
  const tmp = join(root, "tmp");
  const control = join(root, "control");
  mkdirSync(tmp);
  mkdirSync(control);
  git(root, "init", "-q", "--bare", origin);
  git(root, "init", "-q", author);
  const base = commit(author, "a.txt", "one\n", "base");
  const head = commit(author, "a.txt", "one\ntwo\n", "first head");
  git(author, "push", "-q", origin, "HEAD:refs/pull/1/head");
  git(root, "clone", "-q", origin, worktree);
  git(worktree, "checkout", "-q", "--detach", head);
  writeFileSync(join(tmp, "expected-head"), `${head}\n`);
  return { root, origin, author, worktree, tmp, control, base, head };
}

type Fixture = ReturnType<typeof fixture>;

function run(fx: Fixture, mode: string, extraEnv: Record<string, string> = {}) {
  const piLog = join(fx.root, "pi.jsonl");
  const child = spawn(sessionBin, ["--pr", "1", "--prompt", "/skill:pr-review --pr 1", "--timeout", "60"], {
    cwd: fx.worktree,
    env: {
      ...process.env,
      PRSMASH_PI_BIN: fakePi,
      FAKE_PI_MODE: mode,
      FAKE_PI_LOG: piLog,
      PRSMASH_CONTROL_DIR: fx.control,
      PRSMASH_REVIEW_EXPECTED_HEAD_FILE: join(fx.tmp, "expected-head"),
      PRSMASH_REVIEW_RESULT_FILE: join(fx.tmp, "review-result.json"),
      PR_REVIEW_TMPDIR: fx.tmp,
      PRSMASH_SESSION_POLL_SECONDS: "0.1",
      PRSMASH_SESSION_GRACE_SECONDS: "0.5",
      ...extraEnv,
    },
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (c) => (stdout += c));
  child.stderr.on("data", (c) => (stderr += c));
  const done = new Promise<number>((r) => child.on("exit", (code) => r(code ?? -1)));
  const commands = () =>
    existsSync(piLog)
      ? readFileSync(piLog, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l) as { type: string; message?: string })
      : [];
  return { done, out: () => stdout, err: () => stderr, commands };
}

function control(fx: Fixture, head: string): void {
  const path = join(fx.control, `${Date.now()}.json`);
  writeFileSync(`${path}.tmp`, JSON.stringify({ type: "head-moved", head }));
  renameSync(`${path}.tmp`, path);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

test("a quick review prints the final text and exits 0", async () => {
  const fx = fixture();
  const session = run(fx, "quick");
  assert.equal(await session.done, 0);
  assert.match(session.out(), /quick review done/);
  assert.deepEqual(session.commands().map((c) => c.type), ["prompt"]);
});

test("an errored final turn exits 1 with the error on stderr", async () => {
  const fx = fixture();
  const session = run(fx, "error");
  assert.equal(await session.done, 1);
  assert.match(session.err(), /overloaded_error/);
});

test("a new head mid-review is fetched and steered in, and the expected head moves", async () => {
  const fx = fixture();
  const session = run(fx, "steer");
  await sleep(300);
  const next = commit(fx.author, "b.txt", "new\n", "second head");
  git(fx.author, "push", "-q", fx.origin, "HEAD:refs/pull/1/head");
  control(fx, next);

  assert.equal(await session.done, 0);
  const steer = session.commands().find((c) => c.type === "steer");
  assert.ok(steer, "expected a steer command");
  assert.match(steer.message!, new RegExp(`New head ${next}`));
  assert.match(steer.message!, /- b\.txt/);
  assert.match(steer.message!, /second head/);
  assert.equal(readFileSync(join(fx.tmp, "expected-head"), "utf8").trim(), next);
  assert.match(session.out(), /steered review done/);
  assert.equal(git(fx.worktree, "rev-parse", "HEAD"), fx.head, "the worktree checkout is left to the reviewer");
});

test("a force-pushed head aborts the review as superseded (exit 75)", async () => {
  const fx = fixture();
  const session = run(fx, "abortable");
  await sleep(300);
  git(fx.author, "checkout", "-q", "--detach", fx.base);
  const rewritten = commit(fx.author, "c.txt", "rewrite\n", "rewritten head");
  git(fx.author, "push", "-q", "-f", fx.origin, "HEAD:refs/pull/1/head");
  control(fx, rewritten);

  assert.equal(await session.done, 75);
  assert.ok(session.commands().some((c) => c.type === "abort"));
  assert.match(session.out(), /PRSMASH_SUPERSEDED/);
  assert.equal(readFileSync(join(fx.tmp, "expected-head"), "utf8").trim(), fx.head);
});

test("a delta over the steer limit is superseded rather than steered", async () => {
  const fx = fixture();
  const session = run(fx, "abortable", { PRSMASH_STEER_MAX_LINES: "1" });
  await sleep(300);
  const next = commit(fx.author, "big.txt", "1\n2\n3\n", "big change");
  git(fx.author, "push", "-q", fx.origin, "HEAD:refs/pull/1/head");
  control(fx, next);
  assert.equal(await session.done, 75);
  assert.ok(!session.commands().some((c) => c.type === "steer"));
});

test("a head that lands just after the reviewer settles is followed up in the same session", async () => {
  const fx = fixture();
  const session = run(fx, "followup", { PRSMASH_SESSION_GRACE_SECONDS: "3" });
  await sleep(500);
  const next = commit(fx.author, "b.txt", "late\n", "late push");
  git(fx.author, "push", "-q", fx.origin, "HEAD:refs/pull/1/head");
  control(fx, next);
  assert.equal(await session.done, 0);
  const prompts = session.commands().filter((c) => c.type === "prompt");
  assert.equal(prompts.length, 2, "the follow-up goes to the same pi process");
  assert.match(prompts[1].message!, /moved while you were reviewing/);
  assert.match(session.out(), /followed up/);
});

test("a stale notification for a head already covered is ignored", async () => {
  const fx = fixture();
  const session = run(fx, "steer", { PRSMASH_SESSION_GRACE_SECONDS: "0.2" });
  await sleep(300);
  control(fx, fx.head);
  await sleep(500);
  assert.ok(!session.commands().some((c) => c.type === "steer"));
  // Unblock the fake reviewer so the session can finish.
  const next = commit(fx.author, "b.txt", "x\n", "unblock");
  git(fx.author, "push", "-q", fx.origin, "HEAD:refs/pull/1/head");
  control(fx, next);
  assert.equal(await session.done, 0);
});

test("a steer that reaches pi as it settles is reclaimed and sent as a prompt", async () => {
  const fx = fixture();
  const session = run(fx, "late-steer", { PRSMASH_SESSION_GRACE_SECONDS: "1" });
  await sleep(300);
  const next = commit(fx.author, "b.txt", "late\n", "racing push");
  git(fx.author, "push", "-q", fx.origin, "HEAD:refs/pull/1/head");
  control(fx, next);
  assert.equal(await session.done, 0);
  const types = session.commands().map((c) => c.type);
  assert.deepEqual(types, ["prompt", "steer", "clear_queue", "prompt"]);
  assert.match(session.commands()[3].message!, /moved while you were reviewing/);
  assert.match(session.out(), /reclaimed/);
});

test("a fetch failure leaves the control message for a retry", async () => {
  const fx = fixture();
  const session = run(fx, "steer", { PRSMASH_SESSION_GRACE_SECONDS: "0.2", PRSMASH_CONTROL_RETRY_SECONDS: "0.3" });
  await sleep(300);
  const next = commit(fx.author, "b.txt", "x\n", "pushed while origin is unreachable");
  const realOrigin = fx.origin;
  git(fx.worktree, "remote", "set-url", "origin", join(fx.root, "missing.git"));
  control(fx, next);
  await sleep(800);
  assert.ok(!session.commands().some((c) => c.type === "steer"), "nothing to steer while the fetch fails");
  assert.equal(readdirSync(fx.control).filter((f) => f.endsWith(".json")).length, 1, "the message waits for a retry");
  git(fx.author, "push", "-q", realOrigin, "HEAD:refs/pull/1/head");
  git(fx.worktree, "remote", "set-url", "origin", realOrigin);
  assert.equal(await session.done, 0);
  assert.ok(session.commands().some((c) => c.type === "steer"));
});

test("a delta whose patch is bigger than an in-memory buffer is streamed to disk and steered", async () => {
  const fx = fixture();
  const session = run(fx, "steer");
  await sleep(300);
  // One 3 MiB line: a tiny line count, but over execFileSync's default buffer.
  writeFileSync(join(fx.author, "huge.txt"), "x".repeat(3 * 1024 * 1024) + "\n");
  git(fx.author, "add", "huge.txt");
  git(fx.author, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "huge single line");
  const next = git(fx.author, "rev-parse", "HEAD");
  git(fx.author, "push", "-q", fx.origin, "HEAD:refs/pull/1/head");
  control(fx, next);
  assert.equal(await session.done, 0, session.err());
  assert.ok(session.commands().some((c) => c.type === "steer"));
  assert.ok(existsSync(join(fx.tmp, `delta-${fx.head.slice(0, 12)}-${next.slice(0, 12)}.diff`)));
});
