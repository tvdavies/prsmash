import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createServer, type Server } from "node:http";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const daemon = resolve(here, "../prsmashd.ts");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const repo = "acme/widgets";

type Pr = { number: number; head: string; updated: string };

// A fake GitHub that serves the open-PR list with ETags and counts how often
// it had to send a full body.
class FakeGitHub {
  prs: Pr[] = [];
  fullResponses = 0;
  notModified = 0;
  server: Server;
  port = 0;
  constructor() {
    this.server = createServer((req, res) => {
      const body = JSON.stringify(
        this.prs.map((pr) => ({ number: pr.number, head: { sha: pr.head }, updated_at: pr.updated, draft: false, requested_reviewers: [] })),
      );
      const etag = `"${createHash("sha1").update(body).digest("hex")}"`;
      if (req.headers["if-none-match"] === etag) {
        this.notModified += 1;
        res.writeHead(304).end();
        return;
      }
      this.fullResponses += 1;
      res.writeHead(200, { "content-type": "application/json", etag }).end(body);
    });
  }
  async listen(): Promise<void> {
    await new Promise<void>((r) => this.server.listen(0, "127.0.0.1", () => r()));
    this.port = (this.server.address() as { port: number }).port;
  }
}

function sha(n: number): string {
  return n.toString(16).padStart(40, "0");
}

function setup(eligible: number[]) {
  const root = mkdtempSync(join(tmpdir(), "prsmashd-"));
  const bin = join(root, "bin");
  const logRoot = join(root, "logs");
  const state = join(root, "state");
  mkdirSync(bin);
  mkdirSync(state);
  mkdirSync(join(logRoot, "locks"), { recursive: true });
  writeFileSync(join(state, "eligible"), eligible.join("\n"));

  // gh: only `gh auth token` is used.
  writeFileSync(join(bin, "gh"), "#!/usr/bin/env bash\necho test-token\n");
  // Queue script: every eligible PR, at the head the fake GitHub reports.
  writeFileSync(
    join(bin, "queue"),
    `#!/usr/bin/env bash
echo "$*" >> "${state}/queue-calls"
only=""
[[ "$1" == --only ]] && only=",$2,"
prs="[]"
while read -r n || [[ -n "$n" ]]; do
  [[ -z "$n" ]] && continue
  [[ -n "$only" && "$only" != *",$n,"* ]] && continue
  head=$(cat "${state}/head-$n" 2>/dev/null || printf '%040x' "$n")
  prs=$(jq -c --argjson n "$n" --arg h "$head" '. + [{number: $n, headRefOid: $h, title: "PR \\($n)", queueSource: "review-request", repository: {nameWithOwner: "${repo}"}}]' <<<"$prs")
done < "${state}/eligible"
jq -n --argjson prs "$prs" '{repo: "${repo}", user: "me", prs: $prs}'
`,
  );
  // prsmash: hold the PR lock like review_pr_bg does until told to finish.
  writeFileSync(
    join(bin, "prsmash"),
    `#!/usr/bin/env bash
[[ "$1" == --approvals-only ]] && exit 0
queue_file=$3
n=$(jq -r '.prs[0].number' "$queue_file")
echo "$PRSMASH_CONTROL_DIR" > "${state}/started-$n"
exec 9>"${logRoot}/locks/pr-${repo.replace("/", "_")}-$n.lock"
flock 9
until [[ -f "${state}/release-$n" ]]; do sleep 0.05; done
rm -f "${state}/release-$n"
`,
  );
  for (const f of ["gh", "queue", "prsmash"]) chmodSync(join(bin, f), 0o755);
  return { root, bin, logRoot, state };
}

type Env = ReturnType<typeof setup>;

function startDaemon(env: Env, gh: FakeGitHub, extra: Record<string, string> = {}): { child: ChildProcess; out: () => string } {
  const child = spawn(process.execPath, ["--disable-warning=ExperimentalWarning", daemon], {
    env: {
      ...process.env,
      PATH: `${env.bin}:${process.env.PATH}`,
      PRSMASH_REPO: repo,
      PRSMASH_SOURCE_REPO: env.root,
      PRSMASH_LOG_DIR: env.logRoot,
      PRSMASH_BIN: join(env.bin, "prsmash"),
      PRSMASH_DAEMON_QUEUE_SCRIPT: join(env.bin, "queue"),
      PRSMASH_GITHUB_API: `http://127.0.0.1:${gh.port}`,
      PRSMASH_POLL_SECONDS: "0.1",
      PRSMASH_RECHECK_MIN_SECONDS: "0.1",
      PRSMASH_SWEEP_SECONDS: "3600",
      PRSMASH_APPROVALS_SECONDS: "3600",
      PRSMASH_MAX_CONCURRENT_REVIEWS: "2",
      ...extra,
    },
  });
  let out = "";
  child.stdout!.on("data", (c) => (out += c));
  child.stderr!.on("data", (c) => (out += c));
  return { child, out: () => out };
}

const started = (env: Env) =>
  readdirSync(env.state)
    .filter((f) => f.startsWith("started-"))
    .map((f) => Number(f.slice("started-".length)))
    .sort((a, b) => a - b);

async function until(check: () => boolean, what: string, ms = 5000): Promise<void> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (check()) return;
    await sleep(50);
  }
  assert.fail(`timed out waiting for ${what}`);
}

const release = (env: Env, n: number) => writeFileSync(join(env.state, `release-${n}`), "");

test("starts eligible reviews up to the concurrency cap, and the next when a slot frees", async (t) => {
  const gh = new FakeGitHub();
  gh.prs = [1, 2, 3].map((n) => ({ number: n, head: sha(n), updated: "t0" }));
  await gh.listen();
  const env = setup([1, 2, 3]);
  const d = startDaemon(env, gh);
  t.after(() => {
    writeFileSync(join(env.state, "daemon.out"), d.out());
    d.child.kill();
    [1, 2, 3].forEach((n) => release(env, n));
    gh.server.close();
  });

  await until(() => started(env).length === 2, "two reviews to start");
  await sleep(500);
  assert.deepEqual(started(env), [1, 2], "the cap holds the third back");
  release(env, 1);
  await until(() => started(env).length === 3, "the third review to start");
});

test("an unchanged PR list is answered with 304s and causes no queue checks", async (t) => {
  const gh = new FakeGitHub();
  gh.prs = [{ number: 1, head: sha(1), updated: "t0" }];
  await gh.listen();
  const env = setup([]);
  const d = startDaemon(env, gh);
  t.after(() => {
    writeFileSync(join(env.state, "daemon.out"), d.out());
    d.child.kill();
    gh.server.close();
  });

  await until(() => gh.notModified >= 5, "conditional polls");
  assert.equal(gh.fullResponses, 1);
  const calls = readFileSync(join(env.state, "queue-calls"), "utf8").trim().split("\n");
  assert.equal(calls.length, 1, `only the start-up sweep: ${calls.join(" | ")}`);
});

test("a PR that changes is re-checked on its own", async (t) => {
  const gh = new FakeGitHub();
  gh.prs = [1, 2].map((n) => ({ number: n, head: sha(n), updated: "t0" }));
  await gh.listen();
  const env = setup([]);
  const d = startDaemon(env, gh);
  t.after(() => {
    writeFileSync(join(env.state, "daemon.out"), d.out());
    d.child.kill();
    release(env, 2);
    gh.server.close();
  });

  await until(() => gh.notModified >= 2, "a quiet poll");
  writeFileSync(join(env.state, "eligible"), "2");
  gh.prs[1].updated = "t1"; // e.g. our review was requested
  await until(() => started(env).includes(2), "PR 2 to start");
  const calls = readFileSync(join(env.state, "queue-calls"), "utf8").trim().split("\n");
  assert.equal(calls.at(-1), "--only 2");
});

test("a head that moves mid-review is sent to the running review, not queued again", async (t) => {
  const gh = new FakeGitHub();
  gh.prs = [{ number: 7, head: sha(7), updated: "t0" }];
  await gh.listen();
  const env = setup([7]);
  const d = startDaemon(env, gh);
  t.after(() => {
    writeFileSync(join(env.state, "daemon.out"), d.out());
    d.child.kill();
    release(env, 7);
    gh.server.close();
  });

  await until(() => started(env).includes(7), "the review to start");
  const control = readFileSync(join(env.state, "started-7"), "utf8").trim();
  gh.prs[0] = { number: 7, head: sha(77), updated: "t1" };
  await until(() => existsSync(control) && readdirSync(control).some((f) => f.endsWith(".json")), "a control message");
  const file = readdirSync(control).find((f) => f.endsWith(".json"))!;
  assert.deepEqual(JSON.parse(readFileSync(join(control, file), "utf8")), { type: "head-moved", head: sha(77) });
  assert.match(d.out(), /#7 moved to .* mid-review; steering/);
});

test("a review left running by an earlier daemon holds its slot and is not duplicated", async (t) => {
  const gh = new FakeGitHub();
  gh.prs = [1, 2, 3].map((n) => ({ number: n, head: sha(n), updated: "t0" }));
  await gh.listen();
  const env = setup([1, 2, 3]);
  // An earlier daemon's review of #1, still holding the lock.
  const holder = spawn("flock", [join(env.logRoot, "locks", `pr-acme_widgets-1.lock`), "sleep", "30"]);
  await sleep(200);
  const d = startDaemon(env, gh);
  t.after(() => {
    writeFileSync(join(env.state, "daemon.out"), d.out());
    d.child.kill();
    holder.kill();
    [1, 2, 3].forEach((n) => release(env, n));
    gh.server.close();
  });

  await until(() => /already running: #1/.test(d.out()), "the orphan to be found");
  await until(() => started(env).length === 1, "one new review");
  await sleep(500);
  assert.deepEqual(started(env), [2], "#1 is not duplicated and still counts towards the cap");
});

test("a head prsmash already handled is not started again", async (t) => {
  const gh = new FakeGitHub();
  gh.prs = [1, 2].map((n) => ({ number: n, head: sha(n), updated: "t0" }));
  await gh.listen();
  const env = setup([1, 2]);
  mkdirSync(join(env.logRoot, "review-dispositions"), { recursive: true });
  writeFileSync(
    join(env.logRoot, "review-dispositions", `acme_widgets-1-${sha(1)}.json`),
    JSON.stringify({ repo, pr: 1, head: sha(1), source: "commented-review", startedAt: "2026-10-05T10:00:00Z" }),
  );
  const d = startDaemon(env, gh);
  t.after(() => {
    writeFileSync(join(env.state, "daemon.out"), d.out());
    d.child.kill();
    [1, 2].forEach((n) => release(env, n));
    gh.server.close();
  });

  await until(() => started(env).includes(2), "PR 2 to start");
  await sleep(400);
  assert.deepEqual(started(env), [2]);
});
