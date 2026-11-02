// Prepares the RBAC sidecars from the api image (aggregator-dpg #910), so they
// run what this api build was tested with. Runs as an init container with the
// api image, which has node and no shell.
//
// 1. Copies the OPA policy (rbac.rego, edge.rego) and the edge route table
//    (edge/routes.json, read as data.edge) into the shared policy volume.
// 2. Fills in the Envoy template (infra/envoy/envoy.yaml in aggregator-dpg):
//    each placeholder, a variable name between double underscores, becomes that
//    environment variable. A missing variable fails the pod start, as the
//    compose stacks' infra/envoy/render.sh does.
const fs = require('fs');
const path = require('path');

const SRC = '/app/policy';
for (const file of ['rbac.rego', 'edge.rego', 'edge/routes.json']) {
  fs.mkdirSync(path.dirname(`/policy/${file}`), { recursive: true });
  fs.copyFileSync(`${SRC}/rbac/${file}`, `/policy/${file}`);
}

const template = fs.readFileSync(`${SRC}/envoy/envoy.yaml`, 'utf8');
const config = template.replace(/__([A-Z_]+)__/g, (_, name) => {
  const value = process.env[name];
  if (!value) throw new Error(`edge-init: ${name} is not set (needed by the Envoy template)`);
  return value;
});
fs.writeFileSync('/envoy/envoy.yaml', config);
console.log('edge-init: policy copied, Envoy config written');
