terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.63.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

###########
# Get AZ's
###########

data "aws_availability_zones" "available" {
  state = "available"
}

###########
# Get latest AMI
###########

data "aws_ami" "latest" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-kernel-5.10-hvm-2.0.202*-x86_64-gp2"]
  }
}

###########
# VPC & IGW & SubNet
###########

resource "aws_vpc" "prod" {
  cidr_block           = "10.100.0.0/16"
  enable_dns_hostnames = "true"

  tags = {
    Name = "Prod VPC"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.prod.id

  tags = {
    Name = "Main Internet GateWay"
  }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.prod.id
  cidr_block        = "10.100.0.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "Public Subnet"
  }
}

###########
# RouteTable & Route
###########

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.prod.id

  tags = {
    Name = "Public Route Table"
  }
}

resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

###########
# Security Group
###########

resource "aws_security_group" "webserver" {
  name        = "webserversg"
  description = "Allow HTTP traffic"
  vpc_id      = aws_vpc.prod.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all traffic"
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = ["0.0.0.0/0"]
  }
}

###########
# Instance KeyPair
###########

resource "tls_private_key" "pk" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "kp" {
  key_name   = "webserver"
  public_key = tls_private_key.pk.public_key_openssh
}

resource "local_file" "ssh_key" {
  filename        = ".ssh/sshkey.pem"
  content         = tls_private_key.pk.private_key_pem
  file_permission = "0400"
}

###########
# EC2 Instance & EIP
###########

resource "aws_instance" "webserver" {
  ami           = data.aws_ami.latest.image_id
  instance_type = "t2.micro"
  key_name      = aws_key_pair.kp.key_name
  user_data     = <<EOF
                            #!/bin/bash
                            yum -y update
                            yum -y install httpd git
                            usermod -a -G apache ec2-user
                            chown -R ec2-user:apache /var/www
                            systemctl enable httpd
                            systemctl start httpd
                            sleep 30
                            git clone --depth 1 --branch master --no-checkout https://github.com/learning-zone/website-templates.git
                            cd website-templates
                            git sparse-checkout set everest-corporate-business-bootstrap-template
                            git checkout master
                            cp -rf everest-corporate-business-bootstrap-template/* /var/www/html
                      EOF

  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.webserver.id
  }

  tags = {
    Name = "webserver"
  }
}

resource "aws_network_interface" "webserver" {
  subnet_id       = aws_subnet.public.id
  security_groups = [aws_security_group.webserver.id]

  tags = {
    Name = "nic_1"
  }
}

resource "aws_eip" "webserver" {
  tags = {
    Name = format("%s EIP", aws_instance.webserver.tags.Name)
  }
}

resource "aws_eip_association" "webserver_eip" {
  instance_id   = aws_instance.webserver.id
  allocation_id = aws_eip.webserver.id
}

###########
# Public IP Output
###########

output "public_address" {
  value = aws_eip.webserver.public_ip
}
