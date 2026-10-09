# OPA's own API authorisation (`--authorization=basic`) for the aggregator api's
# RBAC sidecar. The decision port is already bound to 127.0.0.1; this also stops
# anything in the pod reading or replacing policies or data.
package system.authz

default allow := false

# The api's two queries (packages/rbac OpaAuthorizer).
allow if {
	input.method == "POST"
	input.path in [["v1", "data", "rbac", "decision"], ["v1", "data", "rbac", "capabilities"]]
}

# Kubelet probes on the diagnostic port.
allow if {
	input.method == "GET"
	input.path == ["health"]
}
