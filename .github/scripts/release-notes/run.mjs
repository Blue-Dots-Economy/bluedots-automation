// IO shell for the create-release workflow. All logic lives in notes.mjs (unit-tested);
// this file only talks to gh/git and the filesystem. Every child process gets an argv
// array (execFileSync), never a shell string, so tags and PR titles are never
// interpreted by a shell.
//
//   MODE=assemble  TAG SHA REPOSITORY GH_TOKEN RUNNER_TEMP GITHUB_STEP_SUMMARY [BASE]
//     BASE is only read for non-sprint tags (default main); sprint tags derive theirs.
//     Writes $RUNNER_TEMP/release-body.md (always) and $RUNNER_TEMP/release-fragment.md
//     (sprint tags only) and appends both to the step summary.
//   MODE=publish   TAG REPOSITORY DOCS_TOKEN RUNNER_TEMP GITHUB_STEP_SUMMARY
//     Puts release-fragment.md on the bluedots-docs `release-notes/<tag>` branch and
//     opens or updates its PR into DOCS_BASE (default main; develop for the dev site).
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import {
  parseSprintTag,
  previousSprintTag,
  previousVersionTag,
  selectSourcePrs,
  resolveBase,
  assembleNotes,
  renderFragment,
  releaseBody,
  fragmentPath,
  docsBranch,
  publishAction,
  docsPrBody,
} from './notes.mjs';

const DOCS_REPO = 'Blue-Dots-Economy/bluedots-docs';
// The docs branch the release-notes PR targets. main publishes to the live site;
// develop feeds the dev deployment, which is how the flow is dry-tested end to end.
const DOCS_BASE = process.env.DOCS_BASE || 'main';
if (!/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(DOCS_BASE)) {
  throw new Error(`DOCS_BASE '${DOCS_BASE}' is not a valid branch name`);
}
const BOT_NAME = 'github-actions[bot]';
const BOT_EMAIL = '41898282+github-actions[bot]@users.noreply.github.com';
const PUSH_ATTEMPTS = 3;
// A PR's updated_at is never earlier than its merged_at, so once the updated-desc
// listing passes the cutoff no later page can hold a PR merged after it. The margin
// absorbs clock skew between a merge and its commit's committer date.
const CUTOFF_MARGIN_MS = 24 * 60 * 60 * 1000;

/** Strings that must never reach a log line or an error message. */
const secrets = [];
const redact = (s) => secrets.reduce((acc, v) => acc.split(v).join('***'), String(s ?? ''));

function env(name) {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set`);
  return v;
}

/** Run a command; returns trimmed stdout. Errors carry redacted stderr, never the raw argv error. */
function run(cmd, args, opts = {}) {
  try {
    return execFileSync(cmd, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: 64 * 1024 * 1024,
      ...opts,
    }).trim();
  } catch (err) {
    const e = new Error(`${cmd} ${redact(args.join(' '))} failed: ${redact(err.stderr || err.message).trim()}`);
    e.stderr = redact(err.stderr);
    throw e;
  }
}

const gh = (args, opts) => run('gh', args, opts);
const ghJson = (args, opts) => JSON.parse(gh(args, opts) || 'null');
const lines = (s) => s.split('\n').map((l) => l.trim()).filter(Boolean);

function appendSummary(text) {
  const f = process.env.GITHUB_STEP_SUMMARY;
  if (f) fs.appendFileSync(f, text.endsWith('\n') ? text : `${text}\n`);
}

const commitDate = (repo, ref) =>
  gh(['api', `repos/${repo}/commits/${ref}`, '--jq', '.commit.committer.date']);

/**
 * Walks closed PRs into `base`, most recently updated first, a page at a time, until
 * `done(pr)` says no later page can matter. --paginate would fetch every page.
 */
function walkMergedPrs(repo, base, done) {
  const out = [];
  for (let page = 1; ; page++) {
    const batch = ghJson([
      'api',
      `repos/${repo}/pulls?state=closed&base=${encodeURIComponent(base)}&sort=updated&direction=desc&per_page=100&page=${page}`,
    ]);
    for (const p of batch) {
      if (done(p)) return out;
      if (p.merged_at) out.push(p);
    }
    if (batch.length < 100) return out;
  }
}

function assemble() {
  const tag = env('TAG');
  const sha = env('SHA');
  const repository = env('REPOSITORY');
  const temp = env('RUNNER_TEMP');
  const repoName = repository.split('/')[1];
  const sprint = parseSprintTag(tag) !== null;
  // The branch the tag was cut from: its PRs are the ones the notes are made of.
  const { base } = resolveBase(tag, process.env.BASE ?? '');

  // Sprint tags look back only at sprint tags (which ones depends on the kind); anything
  // else at its own semver family.
  const tagNames = lines(
    gh(['api', '--paginate', `repos/${repository}/git/matching-refs/tags/${sprint ? '20' : ''}`, '--jq', '.[].ref']),
  ).map((r) => r.replace(/^refs\/tags\//, ''));
  const previousTag = sprint ? previousSprintTag(tagNames, tag) : previousVersionTag(tagNames, tag);
  console.log(`Base: ${base}`);
  console.log(`Previous tag: ${previousTag ?? '(none)'}`);

  let prs;
  if (previousTag) {
    const rangeShas = new Set(
      lines(gh(['api', '--paginate', `repos/${repository}/compare/${previousTag}...${sha}`, '--jq', '.commits[].sha'])),
    );
    const cutoff = Date.parse(commitDate(repository, previousTag)) - CUTOFF_MARGIN_MS;
    const merged = walkMergedPrs(repository, base, (p) => Date.parse(p.updated_at) < cutoff);
    prs = selectSourcePrs(merged, rangeShas, base);
  } else {
    // First release in the family: the range is the single most recently merged PR
    // into the base at or before SHA. "At or before" is ancestry (its merge commit is in
    // SHA's recent history), not a date: GitHub's merged_at can be a second later
    // than the merge commit's own date.
    const ancestors = new Set(
      lines(gh(['api', `repos/${repository}/commits?sha=${sha}&per_page=100`, '--jq', '.[].sha'])),
    );
    let latest = null;
    walkMergedPrs(repository, base, (p) => {
      if (latest && Date.parse(p.updated_at) < Date.parse(latest.merged_at)) return true;
      const [hit] = selectSourcePrs([p], ancestors, base);
      if (hit && (!latest || hit.merged_at > latest.merged_at)) latest = hit;
      return false;
    });
    prs = latest ? [latest] : [];
  }
  console.log(`Source PRs: ${prs.map((p) => `#${p.number}`).join(', ') || '(none)'}`);

  const notes = assembleNotes(prs);
  if (notes.missing.length) {
    console.log(`::warning title=Release notes missing::PRs without release-note sections (listed under Release Notes by title only): ${notes.missing.map((n) => `#${n}`).join(', ')}`);
  }

  const body = releaseBody({ notes, prs, repository, previousTag, tag });
  const bodyFile = path.join(temp, 'release-body.md');
  fs.writeFileSync(bodyFile, body);
  appendSummary(`## Release body for ${tag}\n\nPrevious tag: ${previousTag ?? 'none'}\n\n${body}`);

  if (!sprint) {
    console.log(`${tag} is not a sprint tag; no docs fragment written.`);
    return;
  }
  const fragment = renderFragment(
    {
      repo: repoName,
      tag,
      commit: sha,
      base,
      previous_tag: previousTag,
      cut_at: new Date().toISOString().slice(0, 10),
      release_url: `https://github.com/${repository}/releases/tag/${tag}`,
      prs: prs.map((p) => ({ number: p.number, title: p.title, url: p.html_url })),
    },
    notes,
  );
  fs.writeFileSync(path.join(temp, 'release-fragment.md'), fragment);
  appendSummary(`## Docs fragment (${fragmentPath(tag, repoName)})\n\n\`\`\`\`markdown\n${fragment}\n\`\`\`\``);
}

function publish() {
  const tag = env('TAG');
  const repository = env('REPOSITORY');
  const temp = env('RUNNER_TEMP');
  const token = env('DOCS_TOKEN');
  if (!parseSprintTag(tag)) throw new Error(`${tag} is not a sprint tag; only sprint tags are published`);

  // The token travels as an HTTP header set through GIT_CONFIG_* env vars: never in a
  // URL, argv, .git/config or an error message.
  const basic = Buffer.from(`x-access-token:${token}`).toString('base64');
  secrets.push(token, basic);
  if (process.env.GITHUB_ACTIONS === 'true') console.log(`::add-mask::${basic}`);
  const gitEnv = {
    ...process.env,
    GIT_TERMINAL_PROMPT: '0',
    GIT_CONFIG_COUNT: '1',
    GIT_CONFIG_KEY_0: 'http.https://github.com/.extraheader',
    GIT_CONFIG_VALUE_0: `AUTHORIZATION: basic ${basic}`,
  };
  const ghEnv = { ...process.env, GH_TOKEN: token };
  const repoName = repository.split('/')[1];
  const branch = docsBranch(tag);
  const target = fragmentPath(tag, repoName);

  const fragmentFile = path.join(temp, 'release-fragment.md');
  if (!fs.existsSync(fragmentFile)) throw new Error(`${fragmentFile} not found; run MODE=assemble first`);
  const fragment = fs.readFileSync(fragmentFile, 'utf8');

  const dir = fs.mkdtempSync(path.join(temp, 'bluedots-docs-'));
  const git = (args) => run('git', args, { cwd: dir, env: gitEnv });
  run('git', ['clone', '--no-tags', `https://github.com/${DOCS_REPO}.git`, dir], { env: gitEnv });

  // Remote head of the branch as we found it ('' when absent); the lease for a recreate push.
  const remoteHead = (git(['ls-remote', 'origin', `refs/heads/${branch}`]).split(/\s/)[0]) || '';
  const prs = ghJson(['pr', 'list', '--repo', DOCS_REPO, '--head', branch, '--state', 'all',
    '--json', 'number,url,state,headRefOid'], { env: ghEnv }) ?? [];
  const openPr = prs.find((p) => p.state === 'OPEN') ?? null;
  const closedPrHeads = prs.filter((p) => p.state === 'MERGED' || p.state === 'CLOSED').map((p) => p.headRefOid);
  const action = publishAction({ remoteHead, openPr: Boolean(openPr), closedPrHeads });
  console.log(`Docs branch ${branch}: ${action}${openPr ? ` (PR ${openPr.url})` : ''}`);

  if (action === 'append') {
    git(['fetch', 'origin', `refs/heads/${branch}:refs/remotes/origin/${branch}`]);
    git(['checkout', '-B', branch, `origin/${branch}`]);
  } else {
    // The branch is absent or stale (its head belongs to a merged/closed PR), so it is
    // restarted from main. The lease still refuses the push if it moved since ls-remote.
    git(['checkout', '-B', branch, `origin/${DOCS_BASE}`]);
  }

  fs.mkdirSync(path.join(dir, path.dirname(target)), { recursive: true });
  fs.writeFileSync(path.join(dir, target), fragment);
  git(['add', '--', target]);
  let changed = true;
  try {
    git(['diff', '--cached', '--quiet']);
    changed = false;
  } catch {
    // non-zero exit: there are staged changes
  }

  if (!changed && action === 'recreate') {
    console.log(`${target} on ${DOCS_BASE} already matches; nothing to publish.`);
    appendSummary(`Docs: \`${target}\` is already published on ${DOCS_BASE}.`);
    return;
  }
  if (changed) {
    git(['-c', `user.name=${BOT_NAME}`, '-c', `user.email=${BOT_EMAIL}`, 'commit', '-m', `release-notes: ${repoName} ${tag}`]);
    let force = action === 'recreate';
    for (let attempt = 1; ; attempt++) {
      try {
        git(force
          ? ['push', `--force-with-lease=refs/heads/${branch}:${remoteHead}`, 'origin', `HEAD:refs/heads/${branch}`]
          : ['push', 'origin', `HEAD:refs/heads/${branch}`]);
        break;
      } catch (err) {
        const rejected = /fetch first|non-fast-forward|stale info/i.test(err.stderr ?? '');
        if (!rejected || attempt >= PUSH_ATTEMPTS) throw err;
        // Another repo's run pushed first. Rebase onto it and push without force from now on.
        console.log(`Push rejected (attempt ${attempt}/${PUSH_ATTEMPTS}); rebasing onto origin/${branch}.`);
        git(['-c', `user.name=${BOT_NAME}`, '-c', `user.email=${BOT_EMAIL}`, 'pull', '--rebase', 'origin', branch]);
        force = false;
      }
    }
  } else {
    console.log(`${target} is unchanged on ${branch}; only refreshing the PR body.`);
  }

  const componentsDir = `${path.posix.dirname(target)}/`;
  const components = lines(git(['ls-tree', '--name-only', 'HEAD', componentsDir]));
  const bodyFile = path.join(temp, 'docs-pr-body.md');
  fs.writeFileSync(bodyFile, docsPrBody({ tag, components }));

  let prUrl = openPr?.url;
  if (!prUrl) {
    try {
      prUrl = gh(['pr', 'create', '--repo', DOCS_REPO, '--base', DOCS_BASE, '--head', branch,
        '--title', `release-notes: ${tag}`, '--body-file', bodyFile], { env: ghEnv });
    } catch (err) {
      // A concurrent run may have opened it between our list and create.
      const now = ghJson(['pr', 'list', '--repo', DOCS_REPO, '--head', branch, '--state', 'open', '--json', 'number,url'], { env: ghEnv }) ?? [];
      if (!now.length) throw err;
      prUrl = now[0].url;
    }
  }
  // Always rewrite the body so the component list reflects the branch as it is now.
  gh(['pr', 'edit', prUrl, '--repo', DOCS_REPO, '--body-file', bodyFile], { env: ghEnv });
  console.log(`Docs PR: ${prUrl}`);
  appendSummary(`Docs PR: ${prUrl}\n\nComponents on the branch:\n${components.map((c) => `- \`${c}\``).join('\n')}`);
}

try {
  const mode = env('MODE');
  if (mode === 'assemble') assemble();
  else if (mode === 'publish') publish();
  else throw new Error(`MODE must be assemble or publish, got ${mode}`);
} catch (err) {
  // Workflow-command data must escape %, CR and LF or the message is cut at the first newline.
  const data = redact(err.message).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
  console.error(`::error title=release-notes::${data}`);
  process.exit(1);
}
