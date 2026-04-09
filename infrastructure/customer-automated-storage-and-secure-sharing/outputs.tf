output "api_endpoint" {
  value       = "${aws_api_gateway_stage.prod.invoke_url}/v1/upload"
  description = "API endpoint for software integration (CBT/EMR/LIS/EMS)"
}

output "storage_bucket_name" {
  value       = module.storage_bucket.bucket_name
  description = "Storage bucket for files"
}

output "delivery_bucket_name" {
  value       = module.delivery_bucket.bucket_name
  description = "Delivery bucket for spreadsheets"
}
