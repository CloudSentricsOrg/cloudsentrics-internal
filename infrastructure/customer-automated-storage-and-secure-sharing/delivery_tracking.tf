# Delivery tracking table — records what files have been delivered to prevent duplicates
resource "aws_dynamodb_table" "delivery_tracking" {
  name         = "cloudsentrics-delivery-tracking"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "trackingKey"

  attribute {
    name = "trackingKey"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Project     = "CloudSentrics"
    Purpose     = "FileDelivery-Tracking"
    Environment = "prod"
  }
}
