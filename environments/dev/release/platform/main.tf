module "release" {
  for_each                   = { gateway = "${var.name_prefix}-gateway", core = "${var.name_prefix}-core" }
  source                     = "../../../../modules/dev-release"
  aws_account_id             = var.aws_account_id
  aws_region                 = var.aws_region
  github_repository          = "ranikun-labs/platform-services"
  github_repository_owner_id = "211108135"
  github_repository_id       = "1327477262"
  github_oidc_subjects       = var.github_oidc_subjects[each.key]
  permissions_boundaries     = var.permissions_boundaries[each.key]
  github_oidc_provider_arn   = var.github_oidc_provider_arn
  cluster_name               = var.cluster_name
  service_name               = each.value
  ecr_repository_name        = "ranikun/platform/${each.key}"
  workload                   = each.key
  tags                       = merge(var.tags, { Environment = "dev", Owner = "platform", ManagedBy = "terraform" })
}
output "workloads" {
  value = { for name, release in module.release : name => {
    ecr_repository_name = release.ecr_repository_name
    ecr_repository_url  = release.ecr_repository_url
    ecr_repository_arn  = release.ecr_repository_arn
    publisher_role_arn  = release.publisher_role_arn
    deployer_role_arn   = release.deployer_role_arn
    ecs_service_name    = release.ecs_service_name
    task_family         = release.task_family
  } }
}
