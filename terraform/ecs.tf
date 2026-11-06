# ECS cluster (owned by this stack by default; the service stack only consumes it) and the cluster name/ARN locals.

resource "aws_ecs_cluster" "this" {
  count = var.create_ecs_cluster ? 1 : 0
  name  = "${var.project-tag}-cluster"

  setting {
    name  = "containerInsights"
    value = var.ecs_container_insights ? "enabled" : "disabled"
  }

  tags = {
    projects = var.project-tag
  }
}

locals {
  ecs_cluster_name = var.create_ecs_cluster ? aws_ecs_cluster.this[0].name : "${var.project-tag}-cluster"
  ecs_cluster_arn  = var.create_ecs_cluster ? aws_ecs_cluster.this[0].arn : "arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.project-tag}-cluster"
}
