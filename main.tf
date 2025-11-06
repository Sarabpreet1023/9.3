terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- VPC & networking (simple) ---
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = { Name = "demo-vpc" }
}

resource "aws_subnet" "public_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
}

data "aws_availability_zones" "available" {}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# --- Security Group for ALB (allow 80) ---
resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Allow HTTP"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Security Group for backend EC2s (allow ALB -> instance) ---
resource "aws_security_group" "backend_sg" {
  name   = "backend-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "Allow ALB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- ALB ---
resource "aws_lb" "app_alb" {
  name               = "demo-app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_b.id]
}

resource "aws_lb_target_group" "backend_tg" {
  name     = "backend-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check {
    path = "/api/health"
    matcher = "200-399"
    interval = 30
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend_tg.arn
  }
}

# --- IAM role for instance profile (basic) ---
resource "aws_iam_role" "ec2_role" {
  name = "ec2-basic-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service" ; identifiers = ["ec2.amazonaws.com"] }
  }
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# --- Launch template for backend instances (user_data provided) ---
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners = ["amazon"]
  filter {
    name = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_launch_template" "backend_lt" {
  name_prefix   = "backend-lt-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }
  user_data = base64encode(templatefile("${path.module}/user-data-backend.tpl", {
    repo_url = var.repo_url,
    branch = var.branch
  }))
  tag_specifications {
    resource_type = "instance"
    tags = { Name = "backend-instance" }
  }
  security_group_names = [] # we will attach SG in ASG config
}

# --- Auto Scaling Group to maintain N backend instances ---
resource "aws_autoscaling_group" "backend_asg" {
  name                      = "backend-asg"
  desired_capacity          = var.desired_capacity
  max_size                  = var.max_size
  min_size                  = var.min_size
  vpc_zone_identifier       = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  launch_template {
    id      = aws_launch_template.backend_lt.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.backend_tg.arn]

  tag {
    key                 = "Name"
    value               = "backend-asg-instance"
    propagate_at_launch = true
  }
}

# Attach backend security group to instances by creating a lifecycle hook to modify SGs
# Simpler: create an AutoScaling launch template with security group id directly:
resource "aws_launch_template" "backend_lt_with_sg" {
  name_prefix   = "backend-lt-sg-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }
  user_data = base64encode(templatefile("${path.module}/user-data-backend.tpl", {
    repo_url = var.repo_url,
    branch = var.branch
  }))
  vpc_security_group_ids = [aws_security_group.backend_sg.id]
  tag_specifications {
    resource_type = "instance"
    tags = { Name = "backend-instance" }
  }
}

# Use the second launch template for ASG (replace the earlier one)
resource "aws_autoscaling_group" "backend_asg_real" {
  name                      = "backend-asg-real"
  desired_capacity          = var.desired_capacity
  max_size                  = var.max_size
  min_size                  = var.min_size
  vpc_zone_identifier       = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  launch_template {
    id      = aws_launch_template.backend_lt_with_sg.id
    version = "$Latest"
  }
  target_group_arns = [aws_lb_target_group.backend_tg.arn]
  tag {
    key                 = "Name"
    value               = "backend-asg-instance"
    propagate_at_launch = true
  }
}

output "alb_dns" {
  value = aws_lb.app_alb.dns_name
}
