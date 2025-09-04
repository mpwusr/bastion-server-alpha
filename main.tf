terraform {
  required_version = ">= 1.4.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = ">= 1.54.0"
    }
  }
}

provider "openstack" {
  cloud = "mycloud"
}

# -------------------- Variables --------------------
variable "server_name" { type = string, default = "bastion-almalinux9" }
variable "image_name"  { type = string, default = "AlmaLinux-9" }
variable "flavor_name" { type = string, default = "gp1.micro" }

variable "keypair_name" { type = string, description = "Existing OpenStack keypair name" }

variable "network_id"   { type = string, description = "Tenant/internal network UUID" }
variable "subnet_id"    { type = string, description = "Subnet UUID within network_id (optional for fixed IPs)" }

# IMPORTANT: use the **name** of the external network here, not UUID
variable "external_network_name" {
  type        = string
  description = "External/public network NAME for Floating IPs (what 'openstack network list' shows under Name when External=True)"
}

variable "ssh_ingress_cidr" {
  type        = string
  description = "CIDR allowed to SSH (e.g., 203.0.113.45/32)"
  default     = "0.0.0.0/0"
}

variable "volume_size_gb"   { type = number, default = 20 }
variable "attach_volume_boot"{ type = bool, default = true }

# Either set the key text or leave blank and we read from admin_pubkey_path
variable "admin_pubkey" {
  type        = string
  description = "Single-line SSH public key text"
  default     = ""
}
variable "admin_pubkey_path" {
  type        = string
  description = "Path to public key if admin_pubkey is empty"
  default     = "~/.ssh/id_rsa.pub"
}

variable "tags" { type = map(string), default = {} }

# -------------------- Effective values & data --------------------
locals {
  admin_pubkey_effective = var.admin_pubkey != "" ? var.admin_pubkey : trimspace(file(pathexpand(var.admin_pubkey_path)))
}

data "openstack_images_image_v2" "image" {
  name        = var.image_name
  most_recent = true
}

# -------------------- Security group --------------------
resource "openstack_networking_secgroup_v2" "bastion_sg" {
  name        = "${var.server_name}-sg"
  description = "SSH from allowed CIDR; all egress"
  tags        = [for k, v in var.tags : "${k}:${v}"]
}

resource "openstack_networking_secgroup_rule_v2" "ssh_in" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.ssh_ingress_cidr
  security_group_id = openstack_networking_secgroup_v2.bastion_sg.id
}

resource "openstack_networking_secgroup_rule_v2" "egress_all_v4" {
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.bastion_sg.id
}

resource "openstack_networking_secgroup_rule_v2" "egress_all_v6" {
  direction         = "egress"
  ethertype         = "IPv6"
  security_group_id = openstack_networking_secgroup_v2.bastion_sg.id
}

# -------------------- Cloud-init (user-data) --------------------
locals {
  user_data = <<-CLOUD
    #cloud-config
    users:
      - name: admin
        sudo: ALL=(ALL) NOPASSWD:ALL
        groups: wheel
        shell: /bin/bash
        ssh-authorized-keys:
          - ${local.admin_pubkey_effective}
    ssh_pwauth: false
    package_update: true
    packages:
      - git
      - jq
      - tmux
      - curl
      - unzip
      - python3
      - python3-pip
    runcmd:
      - curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
      - curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
      - install -m 0755 kubectl /usr/local/bin/kubectl
      - rm -f kubectl
      - curl -L https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz | tar xz -C /usr/local/bin k9s
  CLOUD
}

# -------------------- Neutron port (attach SG here) --------------------
resource "openstack_networking_port_v2" "bastion_port" {
  name               = "${var.server_name}-port"
  network_id         = var.network_id
  security_group_ids = [openstack_networking_secgroup_v2.bastion_sg.id]
  admin_state_up     = true

  # (Optional) Pin to a subnet or fixed IP:
  # fixed_ip {
  #   subnet_id = var.subnet_id
  #   # ip_address = "x.x.x.x"
  # }
}

# -------------------- Instance --------------------
resource "openstack_compute_instance_v2" "bastion" {
  name        = var.server_name
  flavor_name = var.flavor_name
  key_pair    = var.keypair_name
  user_data   = local.user_data
  metadata    = var.tags

  # attach the prepared port (with security group)
  network {
    port = openstack_networking_port_v2.bastion_port.id
  }

  # Boot from volume (conditional)
  dynamic "block_device" {
    for_each = var.attach_volume_boot ? [1] : []
    content {
      uuid                  = data.openstack_images_image_v2.image.id
      source_type           = "image"
      destination_type      = "volume"
      volume_size           = var.volume_size_gb
      boot_index            = 0
      delete_on_termination = true
    }
  }

  # If not booting from volume, fall back to image_id
  image_id = var.attach_volume_boot ? null : data.openstack_images_image_v2.image.id
}

# -------------------- Floating IP (Neutron) --------------------
resource "openstack_networking_floatingip_v2" "fip" {
  # Your provider expects 'pool' (NAME of external net), not floating_network_id
  pool = var.external_network_name
}

resource "openstack_networking_floatingip_associate_v2" "fip_assoc" {
  floatingip_id = openstack_networking_floatingip_v2.fip.id
  port_id       = openstack_networking_port_v2.bastion_port.id
}
