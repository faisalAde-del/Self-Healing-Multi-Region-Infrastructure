terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Primary region
provider "aws" {
  alias  = "primary"
  region = var.primary_region
}

# Backup region
provider "aws" {
  alias  = "backup"
  region = var.backup_region
}

#########################
# PRIMARY (us-east-1)
#########################

data "aws_vpc" "primary" {
  provider = aws.primary
  default  = true
}

data "aws_subnets" "primary" {
  provider = aws.primary
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.primary.id]
  }
}

data "aws_ami" "primary" {
  provider    = aws.primary
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_security_group" "primary" {
  provider = aws.primary
  name     = "${var.project_name}-primary-sg"
  vpc_id   = data.aws_vpc.primary.id

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

resource "aws_instance" "primary" {
  provider               = aws.primary
  ami                    = data.aws_ami.primary.id
  instance_type          = "t2.micro"  # FREE TIER
  vpc_security_group_ids = [aws_security_group.primary.id]
  subnet_id              = tolist(data.aws_subnets.primary.ids)[0]

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y httpd
              echo "<h1>Primary Instance (us-east-1)</h1>" > /var/www/html/index.html
              systemctl start httpd
              systemctl enable httpd
              EOF

  tags = {
    Name = "${var.project_name}-primary"
  }
}

########################
# BACKUP (us-west-2) PREP
#########################

data "aws_vpc" "backup" {
  provider = aws.backup
  default  = true
}

data "aws_subnets" "backup" {
  provider = aws.backup
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.backup.id]
  }
}

data "aws_ami" "backup" {
  provider    = aws.backup
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_security_group" "backup" {
  provider = aws.backup
  name     = "${var.project_name}-backup-sg"
  vpc_id   = data.aws_vpc.backup.id

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

# ADD THIS NEW RESOURCE
resource "aws_subnet" "backup" {
  provider                = aws.backup
  vpc_id                  = data.aws_vpc.backup.id
  cidr_block              = "172.31.96.0/20"
  availability_zone       = "us-west-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-backup-subnet"
  }
}

#########################
# MONITORING & LAMBDA
#########################

resource "aws_sns_topic" "alerts" {
  provider = aws.primary
  name     = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  provider  = aws.primary
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic" "cloudwatch" {
  provider = aws.primary
  name     = "${var.project_name}-cloudwatch"
}

resource "aws_cloudwatch_metric_alarm" "instance_status" {
  provider            = aws.primary
  alarm_name          = "${var.project_name}-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1" 
  metric_name         = "StatusCheckFailed_System"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Maximum"
  threshold           = "1"
  treat_missing_data = "breaching"
  alarm_description = "Triggers when primary instance fails"
  alarm_actions       = [aws_sns_topic.cloudwatch.arn]

  dimensions = {
    InstanceId = aws_instance.primary.id
  }
}

resource "aws_iam_role" "lambda" {
  provider = aws.primary
  name     = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_ec2" {
  provider = aws.primary
  role     = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  provider   = aws.primary
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "heal" {
  provider         = aws.primary
  filename         = data.archive_file.lambda.output_path
  function_name    = "${var.project_name}-heal"
  role            = aws_iam_role.lambda.arn
  handler         = "lambda.lambda_handler"
  source_code_hash = data.archive_file.lambda.output_base64sha256
  runtime         = "python3.11"
  timeout         = 60

  environment {
    variables = {
      BACKUP_REGION         = var.backup_region
      BACKUP_AMI            = data.aws_ami.backup.id
      INSTANCE_TYPE         = var.instance_type  # ← ADDED THIS LINE
      BACKUP_SECURITY_GROUP = aws_security_group.backup.id
      BACKUP_SUBNET         = aws_subnet.backup.id
      SNS_TOPIC_ARN         = aws_sns_topic.alerts.arn
    }
  }
}

resource "aws_lambda_permission" "allow_sns" {
  provider      = aws.primary
  statement_id  = "AllowSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.heal.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cloudwatch.arn
}

resource "aws_sns_topic_subscription" "lambda" {
  provider  = aws.primary
  topic_arn = aws_sns_topic.cloudwatch.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.heal.arn
}

#########################
# OUTPUTS
#########################

output "primary_url" {
  value = "http://${aws_instance.primary.public_ip}"
}

output "primary_id" {
  value = aws_instance.primary.id
}

output "quick_test" {
  value = <<-EOT
  
  ✅ DEPLOYED! 
  
  1. Confirm email (check inbox)
  2. Visit: http://${aws_instance.primary.public_ip}
  3. Test: Stop instance ${aws_instance.primary.id} in AWS Console
  4. Wait 2 min → check email
  5. See backup in us-west-2
  
  EOT
}