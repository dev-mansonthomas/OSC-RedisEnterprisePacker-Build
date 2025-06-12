packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.0"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-west-3"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ami_name" {
  type    = string
  default = "ubuntu-ufw-lts-aws-{{timestamp}}"
}

variable "source_ami" {
  type    = string
  default = "ami-007c433663055a1cc" # Ubuntu 22.04 LTS AMI for AWS in eu-west-3
}

variable "redis_tarball_name" {
  type    = string
  default = "redislabs-7.22.0-95-jammy-amd64.tar"
}


source "amazon-ebs" "ubuntu_base_for_redis_enteprise" {
  region                  = var.region
  instance_type           = var.instance_type
  source_ami              = var.source_ami
  ami_name                = var.ami_name
  ssh_username            = "ubuntu"
  associate_public_ip_address = true
  tags = {
    Name = var.ami_name
  }
}

build {
  name    = "ubuntu-ufw-lts"
  sources = ["source.amazon-ebs.ubuntu_base_for_redis_enteprise"]

  post-processor "manifest" {
    output      = "manifest.json"
    strip_path  = true
  }
  
  provisioner "file" {
    source      = "../image_scripts/prepare-redis-install.sh"
    destination = "/home/ubuntu/prepare-redis-install.sh"
  }

  provisioner "file" {
    source      = "../redis-software/${var.redis_tarball_name}"
    destination = "/home/ubuntu/redis-enterprise.tar"
  }

  provisioner "shell" {
    inline = [
      "chmod +x /home/ubuntu/prepare-redis-install.sh",
      "sudo /home/ubuntu/prepare-redis-install.sh"
    ]
  }
}