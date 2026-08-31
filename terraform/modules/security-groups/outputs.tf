output "load_balancer_security_group_id" {
  description = "Security group for the public NLB. Pass this to the Traefik Service annotation aws-load-balancer-security-groups."
  value       = aws_security_group.load_balancer.id
}

output "node_security_group_id" {
  description = "Additional security group attached to worker nodes."
  value       = aws_security_group.nodes.id
}

output "cluster_security_group_id" {
  description = "Additional security group attached to the EKS control plane ENIs."
  value       = aws_security_group.cluster.id
}
