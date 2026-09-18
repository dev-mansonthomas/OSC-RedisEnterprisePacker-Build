packer {
  required_plugins {
    outscale = {
      version = ">= 1.0.0"
      source  = "github.com/outscale/outscale"
    }
  }
  required_version = ">= 1.7.0, < 2.0.0"
}

# All four of these are supplied by build_and_deploy_redis_image_with_packer.sh from
# _my_env.sh. The defaults that used to live here were stale and personal -- a
# hardcoded /Users/... key path, redis_version 7.22.0-95 against an 8.0.2-41 tarball,
# and region eu-west-1 while source_omi only exists in eu-west-2 -- so running
# `packer build` directly either failed or built the wrong thing (TODO T-07).
# Empty defaults keep `packer validate` usable without arguments while still making a
# missing value fail loudly in the precondition below.

variable "keypair_name" {
  type        = string
  description = "Outscale keypair name to inject into the build VM"
  default     = ""
}

variable "keypair_private_file" {
  type        = string
  description = "Path to the matching private key, for Packer's SSH connection"
  default     = ""
}

variable "region" {
  type        = string
  description = "Outscale region; must have an entry in source_omi_by_region"
  default     = ""
}

variable "build_instance_type" {
  type    = string
  default = "tinav5.c2r4p1" #c4.large 2vCPU / 4GB of RAM (cheap instance for dev purpose) https://docs.outscale.com/fr/userguide/Types-de-VM.html
}

variable "root_volume_size" {
  type    = number
  default = 30
}

# Base OMI, resolved by build_and_deploy_redis_image_with_packer.sh.
#
# NOT pinned here on purpose. Outscale republishes Ubuntu 22.04 roughly every two
# months and deregisters old images after about ten, so any ID committed to this file
# expires -- the previous pin, ami-054f16b1, was already gone by 2026-09-17 and would
# have failed the build after uploading the tarball.
#
# The wrapper resolves the newest official Ubuntu x86_64/bsu image by default, so a
# rebuild picks up system patches along with the new Redis Enterprise version. To hold
# the base steady -- shipping a Redis CVE fix while changing as little else as possible
# -- set OUTSCALE_SOURCE_OMI=ami-xxxxxxxx.
#
# Whichever path is taken, the ID and the image name are recorded in the OMI tags and
# the description, so any published image can be traced back to its base.
variable "source_omi" {
  type        = string
  description = "Ubuntu base OMI, resolved or pinned by the build wrapper"
  default     = ""

  validation {
    condition     = can(regex("^(ami-[0-9a-f]+)?$", var.source_omi))
    error_message = "The source_omi variable must be an Outscale OMI id such as ami-88dbc914. It is resolved by build_and_deploy_redis_image_with_packer.sh, so run that wrapper instead of invoking packer directly."
  }
}

variable "source_omi_name" {
  type        = string
  description = "Human-readable name of the base OMI, recorded in tags for traceability"
  default     = ""
}

variable "redis_version" {
  type        = string
  description = "Redis Enterprise version, e.g. 8.0.2-41; derived from the tarball filename"
  default     = ""

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$", var.redis_version))
    error_message = "The redis_version variable must look like 8.0.2-41 (maj.min.patch-build). It is supplied by build_and_deploy_redis_image_with_packer.sh, so run that wrapper instead of invoking packer directly."
  }
}

locals {
  # Évite d’échapper des guillemets dans les chaînes : compose les noms ici
  ts = formatdate("YYYYMMDD-hhmm", timestamp())
  # "-aws-" used to appear here even though the builder is Outscale -- a leftover from
  # before AWS support was dropped in 2e95621 (TODO T-18).
  ami_name           = "packer-redis-enterprise-${var.redis_version}-ubuntu-22-lts-outscale-${local.ts}"
  redis_tarball_name = "redislabs-${var.redis_version}-jammy-amd64.tar"
  common_tags = {
    Name         = local.ami_name
    Project      = "redis-enterprise"
    RedisVersion = var.redis_version
    ManagedBy    = "packer"
    # Which base image this was built from -- the only way to trace a published OMI
    # back to its Ubuntu snapshot once the base has been deregistered upstream.
    SourceOMI     = var.source_omi
    SourceOMIName = var.source_omi_name
  }
}

source "outscale-bsu" "ubuntu_base_for_redis_enterprise" {
  region  = var.region
  vm_type = var.build_instance_type

  source_omi = var.source_omi

  omi_name        = local.ami_name
  omi_description = "Redis Enterprise ${var.redis_version} on Ubuntu 22.04 LTS (${local.ts}), base ${var.source_omi} ${var.source_omi_name}"

  ssh_username     = "outscale"
  communicator     = "ssh"
  ssh_interface    = "public_ip"
  ssh_keypair_name = var.keypair_name
  //todo generate & register keypair
  ssh_private_key_file = var.keypair_private_file

  ssh_timeout = "20m" # more robust after reboot

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_size
    volume_type           = "gp2"
    delete_on_vm_deletion = true
  }

  force_deregister      = true # rebuild idempotent
  force_delete_snapshot = true

  tags          = local.common_tags
  snapshot_tags = local.common_tags
}

build {
  # Provisioner sources use path.root (the template's own directory) rather than
  # CWD-relative paths, so packer validate/build work from anywhere. They used to
  # require being invoked from build_scripts/ (TODO T-08).
  name    = "ubuntu-ufw-lts"
  sources = ["source.outscale-bsu.ubuntu_base_for_redis_enterprise"]

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }

  provisioner "file" {
    source      = "${path.root}/../image_scripts/prepare-and-install-redis-install.sh"
    destination = "/home/outscale/prepare-and-install-redis-install.sh"
  }

  provisioner "file" {
    source      = "${path.root}/../image_scripts/redis-install-answers.txt" # corrige la coquille
    destination = "/home/outscale/redis-install-answers.txt"
  }

  provisioner "file" {
    source      = "${path.root}/../redis-software/${local.redis_tarball_name}"
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