locals {
  global = yamldecode(file(find_in_parent_folders("global-values.yaml"))).global
}

# Skip this unit in `terragrunt run --all` when pritunl_enabled is false.
# Default true → not excluded → included (same as before). Individual
# `apply_tf_pritunl` ignores this and always runs the unit.
exclude {
  if      = !try(local.global.pritunl_enabled, true)
  actions = ["all"]
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "environment" {
  path = "${get_terragrunt_dir()}/../../_common/pritunl.hcl"
}
