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

variable "build_instance_type" {
  type    = string
  default = "t3.large"     # 2 vCPU, 8 GiB RAM
}

variable "root_volume_size" {
  type    = number
  default = 10             # GiB
}


source "amazon-ebs" "ubuntu_base_for_redis_enteprise" {
  region                  = var.region
  instance_type           = var.build_instance_type
  source_ami              = var.source_ami
  ami_name                = var.ami_name
  ssh_username            = "ubuntu"
  associate_public_ip_address = true
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_size
    volume_type           = "gp2"
    delete_on_termination = true
  }
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
    source      = "../image_scripts/redis-install-answsers.txt"
    destination = "/home/ubuntu/redis-install-answsers.txt"
  }

  provisioner "file" {
    source      = "../redis-software/${var.redis_tarball_name}"
    destination = "/home/ubuntu/redis-enterprise.tar"
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive"
    ]
    inline = [
      "chmod +x /home/ubuntu/prepare-redis-install.sh",
      "DEBIAN_FRONTEND=noninteractive sudo -E /home/ubuntu/prepare-redis-install.sh"
    ]
  }
}
# DEBIAN_FRONTEND=noninteractive sudo -E 
# is to fix the following warning/error :
#==> ubuntu-ufw-lts.amazon-ebs.ubuntu_base_for_redis_enteprise: debconf: unable to initialize frontend: Dialog
#==> ubuntu-ufw-lts.amazon-ebs.ubuntu_base_for_redis_enteprise: debconf: (Dialog frontend will not work on a dumb terminal, an emacs shell buffer, or without a controlling terminal.)
#==> ubuntu-ufw-lts.amazon-ebs.ubuntu_base_for_redis_enteprise: debconf: falling back to frontend: Readline
#==> ubuntu-ufw-lts.amazon-ebs.ubuntu_base_for_redis_enteprise: debconf: unable to initialize frontend: Readline
#==> ubuntu-ufw-lts.amazon-ebs.ubuntu_base_for_redis_enteprise: debconf: (This frontend requires a controlling tty.)
#==> ubuntu-ufw-lts.amazon-ebs.ubuntu_base_for_redis_enteprise: debconf: falling back to frontend: Teletype
#==> ubuntu-ufw-lts.amazon-ebs.ubuntu_base_for_redis_enteprise: dpkg-preconfigure: unable to re-open stdin:
