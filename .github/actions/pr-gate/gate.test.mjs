import { test } from 'node:test';
import assert from 'node:assert/strict';
import { hasReleaseNotes } from './gate.mjs';

test('release notes present with content', () => {
  const body = '## Summary\nstuff\n\n## Release Notes\n- Added export button\n';
  assert.equal(hasReleaseNotes(body), true);
});

test('missing release notes heading', () => {
  assert.equal(hasReleaseNotes('## Summary\njust a summary'), false);
});

test('empty body', () => {
  assert.equal(hasReleaseNotes(''), false);
  assert.equal(hasReleaseNotes(null), false);
});

test('heading present but section empty', () => {
  assert.equal(hasReleaseNotes('## Release Notes\n\n## Checklist\n- [ ] x'), false);
});

test('heading present but only an HTML comment (untouched template)', () => {
  const body = '## Release Notes\n<!-- list user-facing changes -->\n';
  assert.equal(hasReleaseNotes(body), false);
});

test('alternate casing and underscore spelling', () => {
  assert.equal(hasReleaseNotes('### release_notes\n- change'), true);
  assert.equal(hasReleaseNotes('# RELEASE NOTES\n- change'), true);
});

test('content stops at next heading', () => {
  const body = '## Release Notes\n- real change\n## Notes\nignored';
  assert.equal(hasReleaseNotes(body), true);
});

test('sub-headings within release notes count as content', () => {
  const body = '## Release Notes\n### Bug fixes\n- Fixed OTP expiry\n### Features\n- Added export';
  assert.equal(hasReleaseNotes(body), true);
});

test('same-level heading ends the release notes section', () => {
  // RN section is empty; a following ## heading must NOT be swallowed as content
  const body = '## Release Notes\n\n## Checklist\n- [x] did things';
  assert.equal(hasReleaseNotes(body), false);
});

test('higher-level heading ends the section', () => {
  const body = '### Release Notes\n- real note\n# Top\nignored';
  assert.equal(hasReleaseNotes(body), true); // content collected before the # heading
});

import { hasDocUpdate } from './gate.mjs';

test('README.md at repo root counts', () => {
  assert.equal(hasDocUpdate(['README.md', 'src/x.ts']), true);
});

test('lowercase readme.md counts', () => {
  assert.equal(hasDocUpdate(['readme.md']), true);
});

test('CLAUDE.md counts', () => {
  assert.equal(hasDocUpdate(['CLAUDE.md']), true);
});

test('nested README counts', () => {
  assert.equal(hasDocUpdate(['packages/schemas/README.md']), true);
});

test('no docs touched', () => {
  assert.equal(hasDocUpdate(['src/a.ts', 'src/b.ts']), false);
});

test('lowercase claude.md does NOT count (must be exact)', () => {
  assert.equal(hasDocUpdate(['claude.md']), false);
});

import { evaluate } from './gate.mjs';

const withNotes = '## Release Notes\n- did a thing';

test('passes when both conditions met', () => {
  const r = evaluate({ body: withNotes, labels: [], files: ['README.md'] });
  assert.equal(r.pass, true);
  assert.equal(r.failures.length, 0);
});

test('fails when both missing', () => {
  const r = evaluate({ body: 'no notes', labels: [], files: ['src/a.ts'] });
  assert.equal(r.pass, false);
  assert.equal(r.failures.length, 2);
});

test('no-release-notes label waives notes only', () => {
  const r = evaluate({ body: 'nope', labels: ['no-release-notes'], files: ['README.md'] });
  assert.equal(r.pass, true);
});

test('no-doc-update label waives docs only', () => {
  const r = evaluate({ body: withNotes, labels: ['no-doc-update'], files: ['src/a.ts'] });
  assert.equal(r.pass, true);
});

test('one waiver does not cover the other failing condition', () => {
  const r = evaluate({ body: 'nope', labels: ['no-doc-update'], files: ['src/a.ts'] });
  assert.equal(r.pass, false);
  assert.equal(r.failures.length, 1);
  assert.match(r.failures[0], /Release Notes/);
});
