locals {
  global_vars              = yamldecode(file(find_in_parent_folders("global-values.yaml")))
  keycloak_length          = try(local.global_vars.global.keycloak_length, 16)
  keycloak_special         = try(local.global_vars.global.keycloak_special, true)
  postgresql_length        = try(local.global_vars.global.postgresql_length, 16)
  postgresql_special       = try(local.global_vars.global.postgresql_special, false)
  redis_length             = try(local.global_vars.global.redis_length, 16)
  redis_special            = try(local.global_vars.global.redis_special, false)
  encryption_string_length = try(local.global_vars.global.encryption_string_length, 32)
  random_string_length     = try(local.global_vars.global.random_string_length, 24)
}

terraform {
  source = "../../modules//random_passwords/"
}

inputs = {
  keycloak_length          = local.keycloak_length
  keycloak_special         = local.keycloak_special
  postgresql_length        = local.postgresql_length
  postgresql_special       = local.postgresql_special
  redis_length             = local.redis_length
  redis_special            = local.redis_special
  encryption_string_length = local.encryption_string_length
  random_string_length     = local.random_string_length
}
