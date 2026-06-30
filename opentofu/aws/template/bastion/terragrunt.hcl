exclude {
  if      = false
  actions = ["all"]
}

include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "environment" {
  path = "${get_terragrunt_dir()}/../../_common/bastion.hcl"
}
