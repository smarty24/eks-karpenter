output "debug_private_subnets" {
  value = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
}
