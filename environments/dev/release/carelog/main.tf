module "release" {
  for_each                   = { carelog = "dev-carelog" }
  source                     = "../../../../modules/dev-release"
  aws_account_id             = var.aws_account_id
  aws_region                 = var.aws_region
  github_repository          = "ranikun-labs/carelog-be"
  github_repository_owner_id = "211108135"
  github_repository_id       = "981081375"
  github_oidc_subjects       = var.github_oidc_subjects[each.key]
  github_oidc_provider_arn   = var.github_oidc_provider_arn
  cluster_name               = var.cluster_name
  service_name               = each.value
  workload                   = each.key
  tags                       = merge(var.tags, { Environment = "dev", Owner = "carelog", ManagedBy = "terraform" })
}
output "workloads" {
  value = { for name, release in module.release : name => {
    ecr_repository_url = release.ecr_repository_url
    ecr_repository_arn = release.ecr_repository_arn
    publisher_role_arn = release.publisher_role_arn
    deployer_role_arn  = release.deployer_role_arn
    ecs_service_name   = release.ecs_service_name
    task_family        = release.task_family
  } }
}
