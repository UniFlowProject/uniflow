# ECS cluster for the Fargate services.

resource "aws_ecs_cluster" "this" {
  name = "${var.project-tag}-cluster"

  setting {
    name  = "containerInsights"
    value = var.ecs_container_insights ? "enabled" : "disabled"
  }
}
