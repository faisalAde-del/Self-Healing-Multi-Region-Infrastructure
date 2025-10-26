# Your email for notifications
variable "alert_email" {
  description = "Your email address for alerts"
  default     = "phaizoladeyemi@gmail.com"
}

# Primary region where main instance runs
variable "primary_region" {
  default = "us-east-1"
}

# Backup region where recovery instance launches
variable "backup_region" {
  default = "us-west-2"
}

# Instance type
variable "instance_type" {
  default = "t2.micro"
}

# Project name 
variable "project_name" {
  default = "cross-region-heal"
}