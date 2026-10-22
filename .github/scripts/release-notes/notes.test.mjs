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
} from './notes.mjs';

test('SECTIONS lists the five extracted headings in order', () => {
  assert.deepEqual(SECTIONS, ['Release Notes', 'In Plain Terms', 'Breaking changes / config', 'What users will notice', 'Deploy ordering']);
});
test('compareTags orders rc and sprint numerically and across years', () => {
  const tags = ['202701-s1-rc1', '202610-s2-rc1', '202610-s10-rc1', '202610-s1-rc10', '202610-s1-rc9'];
  assert.deepEqual([...tags].sort(compareTags),
    ['202610-s1-rc9', '202610-s1-rc10', '202610-s2-rc1', '202610-s10-rc1', '202701-s1-rc1']);
});
test('compareTags throws on a non-sprint tag', () => {
  assert.throws(() => compareTags('v1.0.0', '202610-s1-rc1'));
});
test('parseSprintTag parses a sprint tag', () => {
  assert.deepEqual(parseSprintTag('202610-s2-rc3'),
    { sprint: '202610-s2', rc: 'rc3', rcNum: 3, sprintKey: [202610, 2] });
});
test('parseSprintTag rejects suffixed tags', () => {
  assert.equal(parseSprintTag('202609-s2-rc1-hotfix'), null);
  assert.equal(parseSprintTag('v1.0.0'), null);
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

test('previousSprintTag picks the greatest sprint tag below current, ignoring suffixed', () => {
  const names = ['202609-s1-rc3', '202609-s2-rc1-hotfix', '202610-s1-rc1', '202610-s1-rc2', 'v1.0.0'];
  assert.equal(previousSprintTag(names, '202610-s1-rc2'), '202610-s1-rc1');
  assert.equal(previousSprintTag(names, '202610-s1-rc1'), '202609-s1-rc3');
  assert.equal(previousSprintTag(names, '202609-s1-rc3'), null);
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
  const out = selectSourcePrs(prs, new Set(['sha1', 'sha2', 'sha3', 'sha5']));
  assert.deepEqual(out.map((p) => p.number), [1, 3]);
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

test('fragmentPath and docsBranch', () => {
  assert.equal(fragmentPath('202610-s1-rc2', 'signals-dpg'), 'src/releases/202610-s1/rc2/components/signals-dpg.md');
  assert.equal(docsBranch('202610-s1-rc2'), 'release-notes/202610-s1-rc2');
});

test('publishAction appends only when an open PR exists', () => {
  assert.equal(publishAction({ branchExists: true, openPr: false }), 'recreate');
  assert.equal(publishAction({ branchExists: false, openPr: false }), 'recreate');
  assert.equal(publishAction({ branchExists: true, openPr: true }), 'append');
});

test('validateTag', () => {
  const extra = '^(api|web|worker)-v[0-9]+\\.[0-9]+\\.[0-9]+$';
  assert.equal(validateTag('api-v1.2.0', extra).ok, true);
  assert.equal(validateTag('api-v1.2.0', '').ok, false);
  assert.equal(validateTag('202609-s2-rc1-hotfix', '').ok, false);
  assert.deepEqual(validateTag('202610-s1-rc1', ''), { ok: true, sprint: true });
  assert.deepEqual(validateTag('v1.2.3', ''), { ok: true, sprint: false });
  assert.equal(validateTag('api-v1.2.0', extra).sprint, false);
  assert.ok(validateTag('nope', '').error);
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
