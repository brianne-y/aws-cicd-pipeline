output "alb_dns_name" {
description = "Paste this URL into your browser to reach the Flask application"
value = "http://${aws_lb.main.dns_name}"
}
output "ecr_repository_url" {
description = "ECR URL for docker build and push commands: used in Step 7 and 8"
value = aws_ecr_repository.app.repository_url
}
output "ecs_cluster_name" {
description = "ECS cluster name: used in the GitHub Actions workflow file"
value = aws_ecs_cluster.main.name
}
output "ecs_service_name" {
description = "ECS service name: used in the GitHub Actions workflow file"
value = aws_ecs_service.app.name
}
output "task_definition_family" {
description = "Task definition family name: used in the GitHub Actions workflow file"
value = aws_ecs_task_definition.app.family
}
output "github_actions_role_arn" {
description = "ARN to add as GitHub secret AWS_ROLE_ARN — the OIDC pipeline credential"
value = aws_iam_role.github_actions.arn
}