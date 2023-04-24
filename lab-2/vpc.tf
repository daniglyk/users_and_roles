#-------------------------------------------------------------
#creating s3 bucker
resource "aws_s3_bucket" "test-bucket" {
  bucket = "tf-bucket-daniglyk"
  acl    = "private"  
}

#-------------------------------------------------------------
#creating dynamodb table
resource "aws_dynamodb_table" "basic-dynamodb-table" {
  name           = "dyanmodb"
  billing_mode   = "PROVISIONED"
  read_capacity  = 20
  write_capacity = 20
  hash_key       = "Table_Id"

  attribute {
    name = "Table_Id"
    type = "S"
  }

  tags = {
    Name        = "State"
    Environment = "Dev"
  }
}

terraform {
        backend "s3" {
                bucket = "tf-bucket-daniglyk"
                key    = "dev/terraform.tfstate"
                region = "eu-north-1"
                dynamodb_table = "dyanmodb"
        }
}

#-------------------------------------------------------------
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-north-1a", "eu-north-1b", "eu-north-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  enable_vpn_gateway = true

  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}

data "aws_availability_zones" "available" { 
} 
#-------------------------------------------------------------
#assigning port 80 to nginx

resource "aws_security_group" "demo_sg" {
  name        = "demo_sg"
  description = "allow ssh on 22 & http on port 80"
  vpc_id      = "${module.vpc.vpc_id}"

  ingress {
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  ingress {
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  ingress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["10.0.0.0/16"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }

}
#-------------------------------------------------------------
#Creating and attaching role to ec2 instance
resource "aws_iam_policy" "demo-s3-policy" {
  name        = "admin_policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "*",
        ]
        Effect   = "Allow"
        Resource = [ "arn:aws:iam::aws:policy/AdministratorAccess" ]
      },
    ]
  })
}

resource "aws_iam_role" "demo-role" {
  name = "ec2_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = "RoleForEC2"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_policy_attachment" "demo-attach" {
  name       = "demo-attachment"
  roles      = [aws_iam_role.demo-role.name]
  policy_arn = aws_iam_policy.demo-s3-policy.arn
}

resource "aws_iam_instance_profile" "demo-profile" {
  name = "instance_profile"
  role = aws_iam_role.demo-role.name
}


#----------------------------------------------------------
module "ec2_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 3.0"

  name = "terraform-instance"

  ami                    = "ami-064087b8d355e9051"
  instance_type          = "t3.micro"
  key_name               = "daniglyk"
  user_data              = file("userdata.tpl")
  iam_instance_profile = aws_iam_instance_profile.demo-profile.name
  vpc_security_group_ids = ["${aws_security_group.demo_sg.id}"]
  subnet_id              = "${module.vpc.private_subnets[1]}"
  
  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}
#----------------------------------------------------------
module "ec2_instance_public" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 3.0"

  name = "terraform-instance"

  ami                    = "ami-064087b8d355e9051"
  instance_type          = "t3.small"
  key_name               = "daniglyk"
  iam_instance_profile = aws_iam_instance_profile.demo-profile.name
  vpc_security_group_ids = ["${aws_security_group.demo_sg.id}"]
  subnet_id              = "${module.vpc.public_subnets[1]}"
  associate_public_ip_address = true
  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

#-------------------------------------------------------------
#Creating ALB
resource "aws_lb" "test" {
  name               = "ALB-Terraform"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["${aws_security_group.demo_sg.id}"]
  subnets            = ["${module.vpc.public_subnets[0]}", "${module.vpc.public_subnets[1]}"]
  tags = {
    Environment = "production"
  }
}

resource "aws_lb_target_group" "test" {
  name     = "ALB-Terraform"
  port     = 80
  protocol = "HTTP"
  vpc_id   = "${module.vpc.vpc_id}"
}

resource "aws_lb_target_group_attachment" "test" {
  target_group_arn = aws_lb_target_group.test.arn
  target_id        = "${module.ec2_instance.id}"
  port             = 80
}
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = "${aws_lb.test.arn}"
  port              = "80"

  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.test.arn}"
  }
}
