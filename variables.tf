variable "github_repo" {
description = "GitHub org/repo for OIDC trust policy — e.g.brianne-y/aws-ecs-cicd-pipeline"
type = string
}
variable "alert_email" {
description = "Email address for CloudWatch SNS alerts"
type = string
}
variable "app_name" {
description = "Application name — used as a prefix for all resource names"
type = string
default = "project-3-flask"
}