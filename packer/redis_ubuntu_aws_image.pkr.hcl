packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.0"
    }
  }
  required_version = ">= 1.7.0, < 2.0.0"
}

variable "region" {
  type    = string
  default = "eu-west-3"
}

variable "build_instance_type" {
  type    = string
  default = "t3.large"
}

variable "root_volume_size" {
  type    = number
  default = 30
}

variable "source_ami" {
  type    = string
  default = "ami-007c433663055a1cc" # Ubuntu 22.04 LTS in eu-west-3
}

variable "redis_version" {
  type    = string
  default = "7.22.0-95"
}

locals {
  # Évite d’échapper des guillemets dans les chaînes : compose les noms ici
  ts                 = formatdate("YYYYMMDD-hhmm", timestamp())
  ami_name           = "packer-redis-enterprise-${var.redis_version}-ubuntu-22-lts-aws-${local.ts}"
  redis_tarball_name = "redislabs-${var.redis_version}-jammy-amd64.tar"
  common_tags = {
    Name         = local.ami_name
    Project      = "redis-enterprise"
    RedisVersion = var.redis_version
    ManagedBy    = "packer"
  }
}

source "amazon-ebs" "ubuntu_base_for_redis_enterprise" {
  region                        = var.region
  instance_type                 = var.build_instance_type
  source_ami                    = var.source_ami

  ami_name                      = local.ami_name
  ami_description               = "Redis Enterprise ${var.redis_version} on Ubuntu 22.04 LTS (${local.ts})"

  ssh_username                  = "ubuntu"
  associate_public_ip_address   = true
  ssh_timeout                   = "20m"   # more robust after reboot

  launch_block_device_mappings {
    device_name                 = "/dev/sda1"
    volume_size                 = var.root_volume_size
    volume_type                 = "gp3"
    delete_on_termination       = true
  }

  force_deregister              = true           # rebuild idempotent
  force_delete_snapshot         = true

  tags                          = local.common_tags
  snapshot_tags                 = local.common_tags
}

build {
  name    = "ubuntu-ufw-lts"
  sources = ["source.amazon-ebs.ubuntu_base_for_redis_enterprise"]

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }

  provisioner "file" {
    source      = "../image_scripts/prepare-and-install-redis-install.sh"
    destination = "/home/ubuntu/prepare-and-install-redis-install.sh"
  }

  provisioner "file" {
    source      = "../image_scripts/redis-install-answers.txt" # corrige la coquille
    destination = "/home/ubuntu/redis-install-answers.txt"
  }

  provisioner "file" {
    source      = "../redis-software/${local.redis_tarball_name}"
    destination = "/home/ubuntu/redis-enterprise.tar"
  }

  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline_shebang   = "/bin/bash -eux"
    inline = [
      "set -euxo pipefail",
      "chmod +x /home/ubuntu/prepare-and-install-redis-install.sh",
      "sudo -E /home/ubuntu/prepare-and-install-redis-install.sh"
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