// Tag-name check for the create-release workflow. A thin wrapper over validateTag and
// resolveBase (unit-tested in notes.test.mjs): reads TAG, EXTRA_TAG_PATTERN and BASE
// from the env and prints `<kind> <base>` on stdout, e.g. `candidate develop` or
// `version main`. A BASE that a sprint tag overrides gets a workflow ::notice. On a bad
// tag or base it prints a workflow ::error, and exits 1. Workflow commands go to stderr
// so stdout stays clean for capture.
import { validateTag, resolveBase } from './notes.mjs';

// Workflow-command data must escape %, CR and LF or the message is cut at the first newline.
const esc = (s) => s.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');

const tag = process.env.TAG ?? '';
const input = process.env.BASE ?? '';
const result = validateTag(tag, process.env.EXTRA_TAG_PATTERN ?? '');
if (!result.ok) {
  console.error(`::error title=Bad tag name::${esc(result.error)}`);
  process.exit(1);
}
let resolved;
try {
  resolved = resolveBase(tag, input);
} catch (err) {
  console.error(`::error title=Bad base::${esc(err.message)}`);
  process.exit(1);
}
if (resolved.ignored) {
  console.error(`::notice title=Base ignored::${esc(`${tag} is a ${result.kind} tag, so it is cut from ${resolved.base}; the base input '${input}' was ignored.`)}`);
}
console.log(`${result.kind} ${resolved.base}`);
