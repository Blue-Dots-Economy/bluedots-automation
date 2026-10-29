import test from 'node:test';
import assert from 'node:assert/strict';
import {
  SECTIONS,
  parseSprintTag,
  compareTags,
  extractSection,
  isNone,
  previousSprintTag,
  selectSourcePrs,
  assembleNotes,
  renderFragment,
  fragmentPath,
  docsBranch,
  publishAction,
  validateTag,
  resolveBase,
  releaseBranch,
  previousVersionTag,
  releaseBody,
  docsPrBody,
} from './notes.mjs';

test('SECTIONS lists the five extracted headings in order', () => {
  assert.deepEqual(SECTIONS, ['Release Notes', 'In Plain Terms', 'Breaking changes / config', 'What users will notice', 'Deploy ordering']);
});
test('compareTags orders rc and sprint numerically and across years', () => {
  const tags = ['202701-s1-rc1', '202610-s2-rc1', '202610-s10-rc1', '202610-s1-rc10', '202610-s1-rc9'];
  assert.deepEqual([...tags].sort(compareTags),
    ['202610-s1-rc9', '202610-s1-rc10', '202610-s2-rc1', '202610-s10-rc1', '202701-s1-rc1']);
});
test('compareTags orders candidate < release < hotfix within a sprint, then the next sprint', () => {
  const want = ['202611-s1-rc1', '202611-s1-rc10', '202611-s1', '202611-s1.1', '202611-s1.2', '202611-s1.10', '202611-s2-rc1'];
  const shuffled = ['202611-s1.10', '202611-s2-rc1', '202611-s1', '202611-s1-rc10', '202611-s1.2', '202611-s1-rc1', '202611-s1.1'];
  assert.deepEqual([...shuffled].sort(compareTags), want);
});
test('compareTags throws on a non-sprint tag', () => {
  assert.throws(() => compareTags('v1.0.0', '202610-s1-rc1'));
});
test('parseSprintTag parses all three kinds', () => {
  assert.deepEqual(parseSprintTag('202610-s2-rc3'),
    { sprint: '202610-s2', kind: 'candidate', num: 3, entry: 'rc3', sprintKey: [202610, 2] });
  assert.deepEqual(parseSprintTag('202610-s2'),
    { sprint: '202610-s2', kind: 'release', num: 0, entry: 'release', sprintKey: [202610, 2] });
  assert.deepEqual(parseSprintTag('202610-s2.4'),
    { sprint: '202610-s2', kind: 'hotfix', num: 4, entry: 'hotfix4', sprintKey: [202610, 2] });
});
test('parseSprintTag rejects suffixed tags', () => {
  for (const t of ['202609-s2-rc1-hotfix', '202609-s2-alimco', '202609-s2-up-dhwd', '202609-s2.1-hotfix',
    '202609-s2-rc1.1', '202609-s2.', '202609-s2-rc', 'v1.0.0', '2026-s1']) {
    assert.equal(parseSprintTag(t), null, t);
  }
});
test('extractSection is case-insensitive and stops at same-level heading', () => {
  const md = '## release notes\n- a (#1)\n### sub\n- b\n## In Plain Terms\nx';
  assert.equal(extractSection(md, 'Release Notes').trim(), '- a (#1)\n### sub\n- b');
});
test('extractSection handles regex metacharacters, extra spaces, missing and commented headings', () => {
  const md = '## Breaking changes / config\nNone.\n## Deploy   ordering\nFirst.\n<!--\n## Verification\nhidden\n-->';
  assert.equal(extractSection(md, 'Breaking changes / config').trim(), 'None.');
  assert.equal(extractSection(md, 'Deploy ordering').trim(), 'First.');
  assert.equal(extractSection(md, 'Verification'), null);
  assert.equal(extractSection(md, 'Nope'), null);
  assert.equal(extractSection('', 'Summary'), null);
});
test('isNone', () => {
  assert.ok(isNone('None.')); assert.ok(isNone(' <!-- x --> none ')); assert.ok(isNone(null));
  assert.ok(isNone(''));
  assert.ok(!isNone('- new env var FOO'));
});

test('previousSprintTag for a candidate: greatest earlier candidate or release, any sprint', () => {
  const names = ['202609-s1-rc3', '202609-s2-rc1-hotfix', '202610-s1-rc1', '202610-s1-rc2', 'v1.0.0'];
  assert.equal(previousSprintTag(names, '202610-s1-rc2'), '202610-s1-rc1');
  assert.equal(previousSprintTag(names, '202610-s1-rc1'), '202609-s1-rc3');
  assert.equal(previousSprintTag(names, '202609-s1-rc3'), null);
  const withRelease = ['202610-s1-rc1', '202610-s1-rc2', '202610-s1', '202610-s1.1', '202610-s1.2', '202610-s1-alimco'];
  assert.equal(previousSprintTag(withRelease, '202610-s2-rc1'), '202610-s1');
});
test('previousSprintTag for a release: greatest earlier release only', () => {
  const names = ['202610-s1', '202610-s1.1', '202610-s2-rc1', '202610-s2-rc2', '202610-s1-rc9', '202610-s2-x'];
  assert.equal(previousSprintTag(names, '202610-s2'), '202610-s1');
  assert.equal(previousSprintTag(['202610-s1-rc1', '202610-s1-rc2'], '202610-s1'), null);
});
test('previousSprintTag for a hotfix: greatest earlier release or hotfix in the same sprint', () => {
  const names = ['202610-s1-rc10', '202610-s1', '202610-s1.1', '202610-s1.2', '202610-s2-rc1', '202609-s3', '202610-s1.1-hotfix'];
  assert.equal(previousSprintTag(names, '202610-s1.1'), '202610-s1');
  assert.equal(previousSprintTag(names, '202610-s1.2'), '202610-s1.1');
  assert.equal(previousSprintTag(names, '202610-s1.3'), '202610-s1.2');
  // no release in that sprint: no previous tag, even though an older sprint has one
  assert.equal(previousSprintTag(['202609-s3', '202610-s2-rc1'], '202610-s2.1'), null);
});

const pr = (number, over = {}) => ({
  number, title: `PR ${number}`, body: '', html_url: `https://github.com/o/r/pull/${number}`,
  merged_at: `2026-10-0${number}T00:00:00Z`, merge_commit_sha: `sha${number}`, base: { ref: 'main' }, ...over,
});

test('selectSourcePrs filters by base, merge and range, sorted by merged_at', () => {
  const prs = [
    pr(3), pr(1),
    pr(2, { base: { ref: 'develop' } }),
    pr(4, { merge_commit_sha: 'outside' }),
    pr(5, { merged_at: null }),
  ];
  const range = new Set(['sha1', 'sha2', 'sha3', 'sha5']);
  assert.deepEqual(selectSourcePrs(prs, range, 'main').map((p) => p.number), [1, 3]);
  assert.deepEqual(selectSourcePrs(prs, range, 'develop').map((p) => p.number), [2]);
  assert.deepEqual(selectSourcePrs([pr(6, { base: { ref: 'release/202610-s1' } })], new Set(['sha6']), 'release/202610-s1')
    .map((p) => p.number), [6]);
});
test('selectSourcePrs requires a base', () => {
  assert.throws(() => selectSourcePrs([pr(1)], new Set(['sha1'])));
});

test('assembleNotes: one PR is verbatim, empty section is None., section-less PR is listed', () => {
  const a = pr(8, { body: '## Release Notes\n- Added X\n## In Plain Terms\nPeople can X.\n## Deploy ordering\nNone.\n## Checklist\n- [x]' });
  const b = pr(9, { title: 'Bump deps', body: 'just a bump' });
  const one = assembleNotes([a]);
  assert.ok(one.markdown.includes('## Release Notes\n- Added X'));
  assert.ok(one.markdown.includes('## Breaking changes / config\nNone.'));
  assert.deepEqual(one.missing, []);
  assert.ok(!one.markdown.includes('**#8'));
  const both = assembleNotes([a, b]);
  assert.ok(both.markdown.includes('- Bump deps (#9)'));
  assert.deepEqual(both.missing, [9]);
  assert.ok(both.markdown.includes('**#8 PR 8**'));
  assert.ok(both.markdown.includes('## Deploy ordering\nNone.'));
  const order = SECTIONS.map((s) => both.markdown.indexOf(`## ${s}`));
  assert.deepEqual([...order].sort((x, y) => x - y), order);
});

test('renderFragment emits quoted frontmatter and notes_missing', () => {
  const meta = {
    repo: 'signals-dpg', tag: '202610-s1-rc2', commit: 'a'.repeat(40), base: 'main',
    previous_tag: null, cut_at: '2026-10-14', release_url: 'https://github.com/o/r/releases/tag/x',
    prs: [{ number: 9, title: 'Fix "quotes" and \\ slash', url: 'https://github.com/o/r/pull/9' }],
  };
  const out = renderFragment(meta, { markdown: '## Release Notes\nx\n', missing: [9] });
  const [empty, fm, ...rest] = out.split('---\n');
  assert.equal(empty, '');
  assert.ok(fm.includes(`commit: "${'a'.repeat(40)}"`));
  assert.ok(fm.includes('cut_at: "2026-10-14"'));
  assert.ok(fm.includes('previous_tag: null'));
  assert.ok(fm.includes('notes_missing: true'));
  assert.ok(fm.includes('  - number: 9'));
  assert.ok(fm.includes('title: "Fix \\"quotes\\" and \\\\ slash"'));
  assert.ok(rest.join('---\n').includes('## Release Notes'));
  assert.ok(renderFragment({ ...meta, previous_tag: '202610-s1-rc1', prs: [] }, { markdown: 'm', missing: [] })
    .includes('notes_missing: false'));
  assert.ok(renderFragment({ ...meta, prs: [] }, { markdown: 'm', missing: [] }).includes('prs: []'));
});

test('renderFragment writes the branch the tag was cut from as base', () => {
  const meta = (tag) => ({
    repo: 'r', tag, commit: 'c'.repeat(40), base: resolveBase(tag, '').base, previous_tag: null,
    cut_at: '2026-11-01', release_url: 'u', prs: [],
  });
  const notes = { markdown: 'm', missing: [] };
  assert.ok(renderFragment(meta('202611-s1-rc2'), notes).includes('\nbase: "develop"\n'));
  assert.ok(renderFragment(meta('202611-s1'), notes).includes('\nbase: "main"\n'));
  assert.ok(renderFragment(meta('202611-s1.1'), notes).includes('\nbase: "release/202611-s1"\n'));
});

test('fragmentPath and docsBranch', () => {
  assert.equal(fragmentPath('202610-s1-rc2', 'signals-dpg'), 'src/releases/202610-s1/rc2/components/signals-dpg.md');
  assert.equal(fragmentPath('202610-s1', 'signals-dpg'), 'src/releases/202610-s1/release/components/signals-dpg.md');
  assert.equal(fragmentPath('202610-s1.3', 'signals-dpg'), 'src/releases/202610-s1/hotfix3/components/signals-dpg.md');
  assert.throws(() => fragmentPath('v1.0.0', 'signals-dpg'));
  assert.equal(docsBranch('202610-s1-rc2'), 'release-notes/202610-s1-rc2');
  assert.equal(docsBranch('202610-s1.1'), 'release-notes/202610-s1.1');
});

test('publishAction recreates only an absent or stale branch', () => {
  // open PR: always append
  assert.equal(publishAction({ remoteHead: 'abc', openPr: true, closedPrHeads: ['abc'] }), 'append');
  // branch absent: recreate
  assert.equal(publishAction({ remoteHead: null, openPr: false, closedPrHeads: [] }), 'recreate');
  assert.equal(publishAction({ remoteHead: '', openPr: false, closedPrHeads: ['old'] }), 'recreate');
  // stale branch left by a merged/closed PR: recreate
  assert.equal(publishAction({ remoteHead: 'abc', openPr: false, closedPrHeads: ['zzz', 'abc'] }), 'recreate');
  // live branch, no PR at all (another run pushed, PR not opened yet) or newer than the closed PR: append
  assert.equal(publishAction({ remoteHead: 'abc', openPr: false, closedPrHeads: [] }), 'append');
  assert.equal(publishAction({ remoteHead: 'def', openPr: false, closedPrHeads: ['abc'] }), 'append');
});

test('validateTag returns the kind', () => {
  const extra = '^(api|web|worker)-v[0-9]+\\.[0-9]+\\.[0-9]+$';
  assert.deepEqual(validateTag('202610-s1-rc1', ''), { ok: true, kind: 'candidate' });
  assert.deepEqual(validateTag('202610-s1', ''), { ok: true, kind: 'release' });
  assert.deepEqual(validateTag('202610-s1.2', ''), { ok: true, kind: 'hotfix' });
  assert.deepEqual(validateTag('v1.2.3', ''), { ok: true, kind: 'version' });
  assert.deepEqual(validateTag('api-v1.2.0', extra), { ok: true, kind: 'version' });
  assert.equal(validateTag('api-v1.2.0', '').ok, false);
  assert.ok(validateTag('nope', '').error);
  assert.match(validateTag('x', '(').error, /Invalid extra tag pattern/);
});
test('validateTag rejects suffixed sprint tags', () => {
  for (const t of ['202609-s2-rc1-hotfix', '202609-s2-alimco', '202609-s2-up-dhwd', '202609-s2.1-hotfix']) {
    assert.equal(validateTag(t, '').ok, false, t);
  }
});
test('resolveBase derives the branch for sprint kinds and ignores the input', () => {
  assert.deepEqual(resolveBase('202611-s1-rc2', ''), { base: 'develop', ignored: false });
  assert.deepEqual(resolveBase('202611-s1-rc2', 'develop'), { base: 'develop', ignored: false });
  assert.deepEqual(resolveBase('202611-s1-rc2', 'main'), { base: 'develop', ignored: true });
  assert.deepEqual(resolveBase('202611-s1', 'feature'), { base: 'main', ignored: true });
  assert.deepEqual(resolveBase('202611-s1', undefined), { base: 'main', ignored: false });
  assert.deepEqual(resolveBase('202611-s1.1', 'main'), { base: 'release/202611-s1', ignored: true });
  assert.deepEqual(resolveBase('202611-s1.1', ''), { base: 'release/202611-s1', ignored: false });
});
test('resolveBase uses the input (default main) for version tags', () => {
  assert.deepEqual(resolveBase('v1.2.0', ''), { base: 'main', ignored: false });
  assert.deepEqual(resolveBase('v1.2.0', 'develop'), { base: 'develop', ignored: false });
  assert.deepEqual(resolveBase('api-v1.2.0', 'release/x'), { base: 'release/x', ignored: false });
  assert.throws(() => resolveBase('v1.2.0', 'bad branch'), /not a valid branch name/);
  assert.throws(() => resolveBase('v1.2.0', '-x'), /not a valid branch name/);
});
test('releaseBranch names the sprint branch for release and hotfix tags', () => {
  assert.equal(releaseBranch('202611-s1'), 'release/202611-s1');
  assert.equal(releaseBranch('202611-s1.3'), 'release/202611-s1');
  assert.equal(releaseBranch('202611-s1-rc1'), 'release/202611-s1');
  assert.throws(() => releaseBranch('v1.0.0'));
});

test('validateTag uses the strict v<N>.<N>.<N> form', () => {
  assert.equal(validateTag('v1.0.0-release-test', '').ok, false);
  assert.equal(validateTag('vx.y.z', '').ok, false);
});

test('renderFragment replaces control characters in quoted titles', () => {
  const meta = {
    repo: 'r', tag: '202610-s1-rc1', commit: 'b'.repeat(40), base: 'main', previous_tag: null,
    cut_at: '2026-10-14', release_url: 'u',
    prs: [{ number: 1, title: 'a\u0001b\n# c\tz', url: 'u' }],
  };
  const out = renderFragment(meta, { markdown: 'm', missing: [] });
  assert.ok(out.includes('    title: "a b # c	z"\n'));
});

test('previousVersionTag picks the greatest same-family semver tag below current', () => {
  const tags = ['v1.2.0', 'v1.10.0', 'v1.9.3', 'v2.0.0', 'api-v1.9.9', 'v1.9.3-hotfix', '202609-s1-rc1', 'vx'];
  assert.equal(previousVersionTag(tags, 'v1.10.0'), 'v1.9.3');
  assert.equal(previousVersionTag(tags, 'v2.0.0'), 'v1.10.0');
  assert.equal(previousVersionTag(tags, 'v1.2.0'), null);
  assert.equal(previousVersionTag(['api-v1.0.0', 'web-v1.5.0', 'api-v1.2.0', 'v1.4.0'], 'api-v1.3.0'), 'api-v1.2.0');
  assert.equal(previousVersionTag(tags, '202609-s1-rc2'), null);
});

test('releaseBody appends the PR list and a compare link', () => {
  const notes = { markdown: '## Release Notes\n- X\n', missing: [] };
  const prs = [{ number: 3, title: 'Add X' }, { number: 5, title: 'Fix Y' }];
  const body = releaseBody({ notes, prs, repository: 'o/r', previousTag: 'v1.0.0', tag: 'v1.1.0' });
  assert.ok(body.startsWith('## Release Notes\n- X\n'));
  assert.ok(body.includes('## Pull requests\n- Add X (#3)\n- Fix Y (#5)\n'));
  assert.ok(body.includes('**Full changelog**: https://github.com/o/r/compare/v1.0.0...v1.1.0'));
  const first = releaseBody({ notes, prs: [], repository: 'o/r', previousTag: null, tag: 'v1.0.0' });
  assert.ok(first.includes('## Pull requests\nNone.\n'));
  assert.ok(!first.includes('Full changelog'));
});

test('docsPrBody lists components and the publishing checklist', () => {
  const body = docsPrBody({ tag: '202610-s1-rc2', components: ['src/releases/202610-s1/rc2/components/signals-search.md', 'src/releases/202610-s1/rc2/components/signals-dpg.md'] });
  assert.ok(body.includes('`202610-s1-rc2`'));
  assert.ok(body.includes('- `src/releases/202610-s1/rc2/components/signals-dpg.md`\n- `src/releases/202610-s1/rc2/components/signals-search.md`'));
  assert.ok(body.includes('release-page'));
  assert.ok(body.includes('bluedots-release-tools'));
  assert.ok(body.includes('- [ ] `pnpm build` passes locally (the docs CI does not build PRs); `pnpm check:links` and `pnpm check:style` report nothing new under `src/releases/`.'));
  assert.ok(/- \[ \] .*[Mm]erge/.test(body));
  assert.ok(docsPrBody({ tag: 't', components: [] }).includes('None yet.'));
});
