// Tag-name check for the create-release workflow. A thin wrapper over validateTag
// (unit-tested in notes.test.mjs): reads TAG and EXTRA_TAG_PATTERN from the env and
// prints `true` (sprint tag) or `false` (any other accepted tag) on stdout. On a bad
// tag it prints a workflow ::error to stderr, so stdout stays clean for capture, and
// exits 1.
import { validateTag } from './notes.mjs';

const tag = process.env.TAG ?? '';
const result = validateTag(tag, process.env.EXTRA_TAG_PATTERN ?? '');
if (!result.ok) {
  // Workflow-command data must escape %, CR and LF or the message is cut at the first newline.
  const data = result.error.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
  console.error(`::error title=Bad tag name::${data}`);
  process.exit(1);
}
console.log(result.sprint ? 'true' : 'false');
