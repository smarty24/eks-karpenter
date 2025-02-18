# variables.tf
variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "environment" {
  description = "The name of the environemnt. Values could be dev, staging or prod"
  type        = string
  default     = "dev"
}

variable "cluster_version" {
  description = "K8s cluster version e.g 1.29, 1.30, 1.31, eg.."
  type        = string
}
