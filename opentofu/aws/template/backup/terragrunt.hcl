locals {
  global = yamldecode(file(find_in_parent_folders("global-values.yaml"))).global
}

# Skip this unit in `terragrunt run --all` unless backup_enabled resolves true. The template
# ships backup_enabled: true (see global-values.yaml) — new/synced environments get backup on by
# default. The try(..., false) fallback here only protects an EXISTING per-deployment branch that
# hasn't synced these keys into its own global-values.yaml yet: with the key entirely absent,
# this stays excluded rather than attempting to apply against an unset backup_schedule /
# backup_retention_days and failing on the module's precondition.
exclude {
  if      = !try(local.global.backup_enabled, false)
  actions = ["all"]
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "environment" {
  path = "${get_terragrunt_dir()}/../../_common/backup.hcl"
}
