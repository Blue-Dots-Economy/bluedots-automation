// Pure release-notes assembly for the create-release workflow. No IO, no dependencies.
// parseSprintTag/compareTags/extractSection/isNone mirror bluedots-docs src/lib/releases.mjs
// and the section rule of .github/actions/pr-gate/gate.mjs.

export const SECTIONS = [
  'Release Notes',
  'In Plain Terms',
  'Breaking changes / config',
  'What users will notice',
  'Deploy ordering',
];

const SPRINT_TAG = /^(20\d{4}-s(\d+))-rc(\d+)$/;
const VERSION_TAG = /^v[0-9]+\.[0-9]+\.[0-9]+$/;
const HTML_COMMENT = /<!--[\s\S]*?-->/g;
const HEADING = /^\s{0,3}(#{1,6})\s+/;

export function parseSprintTag(tag) {
  const m = typeof tag === 'string' ? SPRINT_TAG.exec(tag) : null;
  if (!m) return null;
  return {
    sprint: m[1],
    rc: `rc${m[3]}`,
    rcNum: Number(m[3]),
    sprintKey: [Number(m[1].slice(0, 6)), Number(m[2])],
  };
}

function mustParse(tag) {
  const p = parseSprintTag(tag);
  if (!p) throw new Error(`Not a sprint tag: ${tag}`);
  return p;
}

/** Ascending comparison of two sprint tags. Throws on a non-sprint tag. */
export function compareTags(a, b) {
  const pa = mustParse(a);
  const pb = mustParse(b);
  return (
    pa.sprintKey[0] - pb.sprintKey[0] ||
    pa.sprintKey[1] - pb.sprintKey[1] ||
    pa.rcNum - pb.rcNum
  );
}

const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&');

/** Body of the section under `heading`, up to the next heading of the same or higher level. */
export function extractSection(markdown, heading) {
  if (!markdown) return null;
  const words = heading.trim().split(/\s+/).map(escapeRegExp).join('\\s+');
  const wanted = new RegExp(`^\\s{0,3}(#{1,6})\\s*${words}\\s*$`, 'i');
  const lines = markdown.replace(HTML_COMMENT, '').split(/\r?\n/);
  const start = lines.findIndex((l) => wanted.test(l));
  if (start === -1) return null;
  const level = lines[start].match(HEADING)?.[1].length ?? lines[start].match(/#+/)[0].length;
  const out = [];
  for (let i = start + 1; i < lines.length; i++) {
    const h = lines[i].match(HEADING);
    if (h && h[1].length <= level) break;
    out.push(lines[i]);
  }
  return out.join('\n');
}

/** True for null, empty, or "None"/"None." once HTML comments are stripped. */
export function isNone(section) {
  if (section == null) return true;
  const s = section.replace(HTML_COMMENT, '').replace(/\s+/g, ' ').trim();
  return s === '' || /^none\.?$/i.test(s);
}

/** Greatest sprint tag strictly below `current`; suffixed and non-sprint tags are ignored. */
export function previousSprintTag(tagNames, current) {
  const below = tagNames
    .filter((t) => parseSprintTag(t) && compareTags(t, current) < 0)
    .sort(compareTags);
  return below.length ? below[below.length - 1] : null;
}

/** PRs merged into main whose merge commit is in the release range, oldest merge first. */
export function selectSourcePrs(prs, rangeShas) {
  return prs
    .filter((p) => p.merged_at && p.base?.ref === 'main' && rangeShas.has(p.merge_commit_sha))
    .sort((a, b) => (a.merged_at < b.merged_at ? -1 : a.merged_at > b.merged_at ? 1 : 0));
}

/** @returns {{ markdown: string, missing: number[] }} */
export function assembleNotes(prs) {
  const missing = [];
  /** per PR: section name -> trimmed text or null (None/absent) */
  const parsed = prs.map((p) => {
    const sections = {};
    let any = false;
    for (const s of SECTIONS) {
      const text = extractSection(p.body ?? '', s);
      if (text !== null) any = true;
      sections[s] = isNone(text) ? null : text.trim();
    }
    if (!any) missing.push(p.number);
    return { pr: p, sections, any };
  });

  const out = SECTIONS.map((name) => {
    const parts = [];
    for (const { pr, sections, any } of parsed) {
      if (!any) {
        if (name === 'Release Notes') parts.push(`- ${pr.title} (#${pr.number})`);
        continue;
      }
      const text = sections[name];
      if (text === null) continue;
      parts.push(prs.length === 1 ? text : `**#${pr.number} ${pr.title}**\n${text}`);
    }
    return `## ${name}\n${parts.length ? parts.join('\n\n') : 'None.'}\n`;
  });
  return { markdown: out.join('\n'), missing };
}

const q = (s) => `"${String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\r?\n/g, ' ').replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, ' ')}"`;

/** YAML frontmatter (every string double-quoted) followed by the notes markdown. */
export function renderFragment(meta, notes) {
  const lines = [
    '---',
    `repo: ${q(meta.repo)}`,
    `tag: ${q(meta.tag)}`,
    `commit: ${q(meta.commit)}`,
    `base: ${q(meta.base)}`,
    `previous_tag: ${meta.previous_tag == null ? 'null' : q(meta.previous_tag)}`,
    `cut_at: ${q(meta.cut_at)}`,
    `release_url: ${q(meta.release_url)}`,
  ];
  if (meta.prs.length === 0) lines.push('prs: []');
  else {
    lines.push('prs:');
    for (const p of meta.prs) {
      lines.push(`  - number: ${Number(p.number)}`, `    title: ${q(p.title)}`, `    url: ${q(p.url)}`);
    }
  }
  lines.push(`notes_missing: ${notes.missing.length > 0}`, '---', '');
  return lines.join('\n') + notes.markdown;
}

export function fragmentPath(tag, repo) {
  const { sprint, rc } = mustParse(tag);
  return `src/releases/${sprint}/${rc}/components/${repo}.md`;
}

export const docsBranch = (tag) => `release-notes/${tag}`;

/**
 * Restart the docs branch from main only when nothing live can be on it: the branch is
 * absent, or its head is the head of a merged/closed PR (stale). A branch with an open
 * PR, or a live branch whose PR another run hasn't opened yet, is appended to so a
 * concurrent publish is never force-pushed over.
 * @param {{ remoteHead: string|null, openPr: boolean, closedPrHeads: string[] }} state
 * @returns {'append'|'recreate'}
 */
export function publishAction({ remoteHead, openPr, closedPrHeads = [] }) {
  if (openPr) return 'append';
  if (!remoteHead) return 'recreate';
  return closedPrHeads.includes(remoteHead) ? 'recreate' : 'append';
}

/** Accepts v*.*.*, a sprint tag, or a match of `extraPattern` (anchored ERE; empty means none). */
export function validateTag(tag, extraPattern) {
  if (parseSprintTag(tag)) return { ok: true, sprint: true };
  if (VERSION_TAG.test(tag)) return { ok: true, sprint: false };
  if (extraPattern) {
    try {
      if (new RegExp(extraPattern).test(tag)) return { ok: true, sprint: false };
    } catch {
      return { ok: false, sprint: false, error: `Invalid extra tag pattern: ${extraPattern}` };
    }
  }
  return { ok: false, sprint: false, error: `Tag ${tag} is not v*.*.*, a sprint tag, or an allowed pattern` };
}

const FAMILY_TAG = /^(.*?v)(\d+)\.(\d+)\.(\d+)$/;

/**
 * Greatest tag below `current` in the same version family (`v1.2.3`, `api-v1.2.3`),
 * by semver. Tags of other families, suffixed tags and sprint tags are ignored.
 */
export function previousVersionTag(tagNames, current) {
  const parse = (t) => {
    const m = typeof t === 'string' ? FAMILY_TAG.exec(t) : null;
    return m && { family: m[1], v: [Number(m[2]), Number(m[3]), Number(m[4])] };
  };
  const cur = parse(current);
  if (!cur) return null;
  const cmp = (a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2];
  let best = null;
  for (const t of tagNames) {
    const p = parse(t);
    if (!p || p.family !== cur.family || cmp(p.v, cur.v) >= 0) continue;
    if (!best || cmp(p.v, best.v) > 0) best = { tag: t, v: p.v };
  }
  return best ? best.tag : null;
}

/** GitHub release body: the curated notes, the source PR list, and a compare link. */
export function releaseBody({ notes, prs, repository, previousTag, tag }) {
  const list = prs.length ? prs.map((p) => `- ${p.title} (#${p.number})`).join('\n') : 'None.';
  let body = `${notes.markdown}\n## Pull requests\n${list}\n`;
  if (previousTag) {
    body += `\n**Full changelog**: https://github.com/${repository}/compare/${previousTag}...${tag}\n`;
  }
  return body;
}

/** Body of the bluedots-docs `release-notes/<tag>` PR, rewritten on every publish. */
export function docsPrBody({ tag, components }) {
  const list = components.length
    ? [...components].sort().map((c) => `- \`${c}\``).join('\n')
    : 'None yet.';
  return [
    `Release notes for \`${tag}\`, written by each service repo's \`create-release\` workflow.`,
    'Merging this PR publishes the rc on the Releases page.',
    '',
    '## Component notes on this branch',
    list,
    '',
    '## Checklist',
    '- [ ] Run the `release-page` skill (from the `bluedots-release-tools` plugin) to write `notes.md` for this rc, and edit it by hand.',
    '- [ ] `pnpm build` passes locally (the docs CI does not build PRs); `pnpm check:links` and `pnpm check:style` report nothing new under `src/releases/`.',
    '- [ ] Merge to publish.',
    '',
  ].join('\n');
}
