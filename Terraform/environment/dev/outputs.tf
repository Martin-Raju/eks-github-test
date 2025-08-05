output "cluster_id" {
  description = "EKS cluster ID."
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane."
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane."
  value       = module.eks.cluster_security_group_id
}

output "region" {
  description = "AWS region"
  value       = var.aws_region
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "EKS_Cluster_Name" {
  description = "AWS Cluster Name"
  value       = var.cluster_name
}

output "S3_Bucket_Name" {
  description = "AWS S3_Bucket Name"
  value       = var.bucket_name
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "iam_username" {
  value = local.iam_username
}
