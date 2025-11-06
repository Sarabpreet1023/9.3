variable "aws_region" { default = "us-east-1" }
variable "instance_type" { default = "t3.micro" }
variable "repo_url" { type = string }
variable "branch" { default = "main" }
variable "desired_capacity" { default = 2 }
variable "min_size" { default = 2 }
variable "max_size" { default = 3 }
