packer {
  required_plugins {
    outscale = {
      version = ">= 1.0.0"
      source  = "github.com/outscale/outscale"
    }
  }
  required_version = ">= 1.7.0, < 2.0.0"
}

variable "keypair_name" {
  type    = string
  default = "outscale-tmanson-keypair"
}

variable "keypair_private_file" {
  type    = string
  default = "/Users/thomas.manson/.ssh/outscale-tmanson-keypair.rsa"
}

variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "build_instance_type" {
  type    = string
  default = "tinav5.c2r4p1" #c4.large 2vCPU / 4GB of RAM (cheap instance for dev purpose) https://docs.outscale.com/fr/userguide/Types-de-VM.html
}

variable "root_volume_size" {
  type    = number
  default = 30
}

variable "source_omi" {
  type    = string
  default = "ami-054f16b1" # Ubuntu 22.04 LTS in eu-west-2 Outscale | https://docs.outscale.com/fr/userguide/Ubuntu-22.04-2025.07.07.html
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

source "outscale-bsu" "ubuntu_base_for_redis_enterprise" {
  region                        = var.region
  vm_type                       = var.build_instance_type
  
  source_omi                    = var.source_omi

  omi_name                      = local.ami_name
  omi_description               = "Redis Enterprise ${var.redis_version} on Ubuntu 22.04 LTS (${local.ts})"

  ssh_username                  = "outscale"
  communicator                  = "ssh"
  ssh_interface                 = "public_ip"
  ssh_keypair_name              = var.keypair_name
  //todo generate & register keypair
  ssh_private_key_file          = var.keypair_private_file

  ssh_timeout                   = "20m"   # more robust after reboot

  launch_block_device_mappings {
    device_name                 = "/dev/sda1"
    volume_size                 = var.root_volume_size
    volume_type                 = "gp2"
    delete_on_vm_deletion       = true
  }

  force_deregister              = true           # rebuild idempotent
  force_delete_snapshot         = true

  tags                          = local.common_tags
  snapshot_tags                 = local.common_tags
}

build {
  name    = "ubuntu-ufw-lts"
  sources = ["source.outscale-bsu.ubuntu_base_for_redis_enterprise"]

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }

  provisioner "file" {
    source      = "../image_scripts/prepare-and-install-redis-install.sh"
    destination = "/home/outscale/prepare-and-install-redis-install.sh"
  }

  provisioner "file" {
    source      = "../image_scripts/redis-install-answers.txt" # corrige la coquille
    destination = "/home/outscale/redis-install-answers.txt"
  }

  provisioner "file" {
    source      = "../redis-software/${local.redis_tarball_name}"
    destination = "/home/outscale/redis-enterprise.tar"
  }

  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
    inline_shebang   = "/bin/bash -eux"
    inline = [
      "set -euxo pipefail",
      "chmod +x /home/outscale/prepare-and-install-redis-install.sh",
      "sudo -E /home/outscale/prepare-and-install-redis-install.sh"
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