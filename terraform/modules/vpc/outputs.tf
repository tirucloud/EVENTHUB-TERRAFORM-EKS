output "vpc_id" {
  description = "VPC identifier."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet identifiers, one per availability zone."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet identifiers, one per availability zone. EKS nodes live here."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability zones the subnets span."
  value       = local.azs
}

output "internet_gateway_id" {
  description = "Internet gateway identifier."
  value       = aws_internet_gateway.this.id
}

output "nat_gateway_ids" {
  description = "NAT gateway identifiers."
  value       = aws_nat_gateway.this[*].id
}

output "nat_public_ips" {
  description = "Elastic IPs the cluster egresses from. Hand these to anyone who needs to allowlist your outbound traffic."
  value       = aws_eip.nat[*].public_ip
}

output "private_route_table_ids" {
  description = "Private route table identifiers."
  value       = aws_route_table.private[*].id
}
