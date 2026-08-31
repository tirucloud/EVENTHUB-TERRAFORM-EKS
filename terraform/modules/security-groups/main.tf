# Security groups that supplement the ones EKS manages for itself.
#
# EKS already creates a cluster security group allowing control plane and nodes
# to talk to each other; nothing here replaces that. These add the three rules
# EKS cannot infer: who may reach the API server, what the load balancer may
# reach, and what the nodes may reach outbound.
#
# Every rule is a separate aws_vpc_security_group_*_rule resource rather than an
# inline block. Inline rules are all-or-nothing — Terraform replaces the whole
# set on any change — while separate resources can be added and removed one at a
# time, and each carries its own description in the console.

# ------------------------------------------------------------------------------
# Load balancer: the only group with an open door to the internet
# ------------------------------------------------------------------------------

resource "aws_security_group" "load_balancer" {
  name        = "${var.name}-lb"
  description = "Public entry point for the NLB fronting Traefik"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-lb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "lb_http" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.load_balancer.id
  description       = "HTTP from ${each.value} (Traefik redirects this to HTTPS)"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "lb_https" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.load_balancer.id
  description       = "HTTPS from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "lb_to_nodes" {
  security_group_id            = aws_security_group.load_balancer.id
  description                  = "Forward traffic to the Traefik pods on the nodes"
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Nodes: additional group attached to the managed node group launch template
# ------------------------------------------------------------------------------

resource "aws_security_group" "nodes" {
  name        = "${var.name}-nodes"
  description = "Additional rules for EKS worker nodes"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name}-nodes"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Pod-to-pod traffic across nodes. With the VPC CNI every pod has a real VPC
# address, so a call from booking-service to event-service on another node is
# ordinary VPC traffic and needs an explicit rule.
resource "aws_vpc_security_group_ingress_rule" "nodes_self" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "Node to node, all ports (pod to pod traffic)"
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"

  tags = var.tags
}

# NLB target-type ip sends traffic straight to the pod address on the container
# port, so the Traefik web (8000) and websecure (8443) ports must be reachable.
resource "aws_vpc_security_group_ingress_rule" "nodes_from_lb_pod_ports" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "Load balancer to Traefik pod ports (NLB ip target type)"
  referenced_security_group_id = aws_security_group.load_balancer.id
  from_port                    = 8000
  to_port                      = 8443
  ip_protocol                  = "tcp"

  tags = var.tags
}

# Kept so that switching the NLB to target-type instance does not require a
# security group change mid-session.
resource "aws_vpc_security_group_ingress_rule" "nodes_from_lb_nodeports" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "Load balancer to NodePort range (NLB instance target type)"
  referenced_security_group_id = aws_security_group.load_balancer.id
  from_port                    = 30000
  to_port                      = 32767
  ip_protocol                  = "tcp"

  tags = var.tags
}

# Nodes must reach ECR, the EKS control plane endpoint, S3 and package mirrors.
# Restricting egress here breaks image pulls in ways that are tedious to debug.
resource "aws_vpc_security_group_egress_rule" "nodes_all" {
  security_group_id = aws_security_group.nodes.id
  description       = "All outbound traffic (image pulls, control plane, DNS)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Cluster: additional group attached to the EKS control plane ENIs
# ------------------------------------------------------------------------------

resource "aws_security_group" "cluster" {
  name        = "${var.name}-cluster"
  description = "Additional rules for the EKS control plane ENIs"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-cluster" })

  lifecycle {
    create_before_destroy = true
  }
}

# Lets anything inside the VPC — a bastion, a CI runner, a VPN client — reach
# the private API server endpoint.
resource "aws_vpc_security_group_ingress_rule" "cluster_api_from_vpc" {
  security_group_id = aws_security_group.cluster.id
  description       = "Kubernetes API from inside the VPC"
  cidr_ipv4         = var.vpc_cidr
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  description       = "All outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = var.tags
}
