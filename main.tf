terraform {
  required_version = ">= 1.4.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = ">= 1.54.0"
    }
  }
}

# -------------------- Provider --------------------
variable "cloud"  {
  type    = string
  default = "mycloud"
}

variable "region" {
  type    = string
  default = "USE1"
}

provider "openstack" {
  cloud  = var.cloud
  region = var.region
}

# -------------------- Variables --------------------
variable "server_name" {
  type    = string
  default = "bastion-ubuntu"
}

variable "image_name" {
  type    = string
  default = "noble-server-20241105" # Ubuntu 24.04
}

variable "flavor_name" {
  type    = string
  default = "gp1.micro"
}

# Keypair management (created per-region)
variable "keypair_name" {
  type = string
} # e.g. "bastion-key"

variable "admin_pubkey" {
  type    = string
  default = ""
} # paste pubkey OR leave blank to read from path

variable "admin_pubkey_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}

# Existing network/subnet (must be from the same region)
variable "network_id" {
  type = string
} # Neutron network UUID

variable "subnet_id" {
  type = string
} # Subnet UUID within network

# Reuse an existing security group (avoid quota)
variable "existing_sg_name" {
  type    = string
  default = "default"         # change to your SG name
}

# Optional: allow Terraform to add SSH rule to that SG
variable "manage_sg_rules" {
  type    = bool
  default = false             # set true if you want TF to add the SSH rule below
}

variable "ssh_ingress_cidr" {
  type    = string
  default = "10.0.0.0/8"      # set to your VPN/internal CIDR
}

# Root disk strategy
variable "attach_volume_boot" {
  type    = bool
  default = false             # false = ephemeral boot
}

variable "volume_size_gb" {
  type    = number
  default = 20
}

variable "volume_type" {
  type    = string
  default = ""                # e.g. "ceph", "__DEFAULT__" (optional)
}

# Tags
variable "tags" {
  type    = map(string)
  default = {}
}

# -------------------- Locals --------------------
locals {
  admin_pubkey_effective = var.admin_pubkey != "" ? var.admin_pubkey : trimspace(file(pathexpand(var.admin_pubkey_path)))
}

# -------------------- Image --------------------
data "openstack_images_image_v2" "image" {
  name        = var.image_name
  most_recent = true
}

# -------------------- Security group (reused) --------------------
# Lookup, do not create
data "openstack_networking_secgroup_v2" "bastion_sg" {
  name = var.existing_sg_name
  # tenant_id = var.tenant_id  # uncomment if needed to disambiguate tenants/projects
}

# Optionally add SSH ingress to the existing SG
resource "openstack_networking_secgroup_rule_v2" "ssh_in" {
  count             = var.manage_sg_rules ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.ssh_ingress_cidr
  security_group_id = data.openstack_networking_secgroup_v2.bastion_sg.id
}

# -------------------- Keypair (per region) --------------------
resource "openstack_compute_keypair_v2" "bastion_key" {
  name       = var.keypair_name
  public_key = local.admin_pubkey_effective
}

# -------------------- Port pinned to your existing subnet --------------------
resource "openstack_networking_port_v2" "bastion" {
  name           = "${var.server_name}-port"
  network_id     = var.network_id
  admin_state_up = true

  # Ports use SG **IDs**
  security_group_ids = [data.openstack_networking_secgroup_v2.bastion_sg.id]

  fixed_ip {
    subnet_id = var.subnet_id
    # ip_address = "10.x.x.x" # (optional) pin a static IP within the subnet
  }

  tags = [for k, v in var.tags : "${k}:${v}"]
}

# -------------------- Cloud-init --------------------
# Ubuntu user + TEMP password login for console (set ssh_pwauth=false later for security)
locals {
  user_data = <<-CLOUD
    #cloud-config
    users:
      - name: ubuntu
        sudo: ALL=(ALL) NOPASSWD:ALL
        groups: sudo
        shell: /bin/bash
        lock_passwd: false

    ssh_pwauth: true
    chpasswd:
      list: |
        ubuntu:MyNewPass123!
      expire: False

    package_update: true
    packages:
      - ca-certificates
      - curl
      - git
      - jq
      - tmux
      - unzip
      - gnupg
      - lsb-release
      - python3
      - python3-pip
      - python3-openstackclient

    runcmd:
      # --- HashiCorp APT repo + Terraform (fixes NO_PUBKEY) ---
      - bash -lc 'set -euo pipefail'
      - bash -lc 'install -d -m 0755 /usr/share/keyrings'
      - bash -lc 'curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg'
      - bash -lc 'chmod 644 /usr/share/keyrings/hashicorp-archive-keyring.gpg'
      - bash -lc 'echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com noble main" > /etc/apt/sources.list.d/hashicorp.list'
      - bash -lc 'apt-get update && apt-get install -y terraform && terraform -version'
    
      # --- (optional) kubectl / helm / k9s ---
      - bash -lc 'KVER=$(curl -Ls https://dl.k8s.io/release/stable.txt); curl -LO https://dl.k8s.io/release/$${KVER}/bin/linux/amd64/kubectl && install -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl'
      - bash -lc 'curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash'
      - bash -lc 'TMP=$(mktemp -d) && cd "$TMP" && curl -L https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz -o k9s.tgz && tar xzf k9s.tgz && install -m 0755 k9s /usr/local/bin/k9s && cd / && rm -rf "$TMP"'
    
      # --- sanity ---
      - bash -lc 'terraform -version; kubectl version --client || true; helm version || true; k9s version || true'
  CLOUD
}

# -------------------- Instance --------------------
resource "openstack_compute_instance_v2" "bastion" {
  name        = var.server_name
  flavor_name = var.flavor_name
  key_pair    = openstack_compute_keypair_v2.bastion_key.name
  user_data   = local.user_data
  metadata    = var.tags

  # Nova uses SG **names**
  security_groups = [data.openstack_networking_secgroup_v2.bastion_sg.name]

  # Attach the pre-created port (ensures exact subnet)
  network { port = openstack_networking_port_v2.bastion.id }

  # Boot strategy (toggle with var.attach_volume_boot)
  dynamic "block_device" {
    for_each = var.attach_volume_boot ? [1] : []
    content {
      uuid                  = data.openstack_images_image_v2.image.id
      source_type           = "image"
      destination_type      = "volume"
      volume_size           = var.volume_size_gb
      boot_index            = 0
      delete_on_termination = true
      volume_type           = var.volume_type != "" ? var.volume_type : null
    }
  }

  # If not boot-from-volume, use the image directly (ephemeral root disk)
  image_id = var.attach_volume_boot ? null : data.openstack_images_image_v2.image.id
}

# -------------------- Outputs --------------------
output "bastion_instance_id" { value = openstack_compute_instance_v2.bastion.id }
output "bastion_port_id"     { value = openstack_networking_port_v2.bastion.id }
output "bastion_fixed_ip" {
  value = one([for ip in openstack_networking_port_v2.bastion.fixed_ip : ip.ip_address])
}
