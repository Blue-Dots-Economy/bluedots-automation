// Pure logic for the develop-PR gate. No IO, no dependencies.

const RELEASE_NOTES_HEADING = /^\s{0,3}#{1,6}\s*release[ _-]?notes\s*$/i;
const ANY_HEADING = /^\s{0,3}#{1,6}\s+/;

export function extractReleaseNotesSection(body) {
  if (!body) return null;
  const lines = body.split(/\r?\n/);
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (RELEASE_NOTES_HEADING.test(lines[i])) {
      start = i + 1;
      break;
    }
  }
  if (start === -1) return null;
  const collected = [];
  for (let i = start; i < lines.length; i++) {
    if (ANY_HEADING.test(lines[i])) break;
    collected.push(lines[i]);
  }
  return collected.join('\n');
}

export function hasReleaseNotes(body) {
  const section = extractReleaseNotesSection(body);
  if (section === null) return false;
  const stripped = section
    .replace(/<!--[\s\S]*?-->/g, '') // drop HTML comments (template placeholders)
    .replace(/\s+/g, ' ')
    .trim();
  return stripped.length > 0;
}

export function hasDocUpdate(files) {
  return files.some((f) => {
    const base = f.split('/').pop();
    return base.toLowerCase() === 'readme.md' || base === 'CLAUDE.md';
  });
}

export function evaluate({ body, labels, files }) {
  const labelSet = new Set(labels);
  const releaseNotesOk = hasReleaseNotes(body) || labelSet.has('no-release-notes');
  const docsOk = hasDocUpdate(files) || labelSet.has('no-doc-update');
  const failures = [];
  if (!releaseNotesOk) {
    failures.push(
      'Missing a non-empty "## Release Notes" section in the PR description (or add the `no-release-notes` label).',
    );
  }
  if (!docsOk) {
    failures.push(
      'This PR does not modify README.md or CLAUDE.md (or add the `no-doc-update` label).',
    );
  }
  return { pass: releaseNotesOk && docsOk, releaseNotesOk, docsOk, failures };
}
