# OPA's own API authorisation (`--authorization=basic`) for the aggregator api's
# RBAC sidecar. The REST port is already bound to 127.0.0.1; this also stops
# anything in the pod reading or replacing policies or data it has no business
# with. Envoy's ext_authz check is on the separate gRPC port, which this policy
# does not govern.
package system.authz

default allow := false

# The api's two queries (packages/rbac OpaAuthorizer).
allow if {
	input.method == "POST"
	input.path in [["v1", "data", "rbac", "decision"], ["v1", "data", "rbac", "capabilities"]]
}

# The api publishes its role catalogue for the edge policy (data.catalogue,
# apps/api/src/services/authz/edge-catalogue.ts) at boot and every refresh.
allow if {
	input.method == "PUT"
	input.path == ["v1", "data", "catalogue"]
}

# Kubelet probes on the diagnostic port.
allow if {
	input.method == "GET"
	input.path == ["health"]
}
