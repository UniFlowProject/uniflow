# Service discovery: private Cloud Map namespace and the service entries that ECS services register into.

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = "${var.project-tag}.local"
  description = "Private service discovery namespace for ${var.project-tag}"
  vpc         = aws_vpc.uniflow_vpc.id

  tags = {
    Name     = "${var.project-tag}-namespace"
    projects = var.project-tag
  }
}

# The ECS service in uniflow-academic-service/terraform registers its tasks here.
resource "aws_service_discovery_service" "academic" {
  name = "academic"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  tags = {
    Name     = "${var.project-tag}-academic-discovery"
    projects = var.project-tag
  }
}
