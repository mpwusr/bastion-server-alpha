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
  # region = "AUE1"
}

# -------------------- Variables --------------------
variable "server_name"        { type = string, default = "bastion-almalinux9" }
variable "image_name"         { type = string, default = "AlmaLinux-9" }
variable "flavor_name"        { type = string, default = "gp1.micro" }
variable "keypair_name"       { type = string }

# Existing external/public network NAME (for floating IP pool)
variable "external_network_name" { type = string }

# We are NOT creating a tenant network
variable "create_tenant_network" { type = bool, default = false }

# >>> Existing subnet we want to attach to (your values) <<<
# GP-net1 10.40.144.0/20
variable "subnet_id"   { type = string, default = "db95ad6f-b129-41e7-857a-77fdfe95216c" }
variable "subnet_name" { type = string, default = "GP-net1" } # informational only

# Security / boot
variable "ssh_ingress_cidr"   { type = string, default = "0.0.0.0/0" }
variable "volume_size_gb"     { type = number, default = 20 }
variable "attach_volume_boot" { type = bool,   default = true }

# SSH key: paste text or read from file
variable "admin_pubkey"      { type = string, default = "" }
variable "admin_pubkey_path" { type = string, default = "~/.ssh/id_rsa.pub" }

# Allocate Floating IP?
variable "allocate_fip" { type = bool, default = true }

variable "tags" { type = map(string), default = {} }

# -------------------- Locals & Data --------------------
locals {
  admin_pubkey_effective = var.admin_pubkey != "" ? var.admin_pubkey : trimspace(file(pathexpand(var.admin_pubkey_path)))
}

data "openstack_images_image_v2" "image" {
  name        = var.image_name
  most_recent = true
}

# Resolve external network by NAME (for FIP pool)
data "openstack_networking_network_v2" "external" {
  name = var.external_network_name
}

# Resolve target SUBNET (we'll derive network_id from it)
data "openstack_networking_subnet_v2" "target" {
  id = var.subnet_id
}

# The Neutron network that contains the target subnet
locals {
  internal_network_id = data.openstack_networking_subnet_v2.target.network_id
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

# -------------------- Cloud-init --------------------
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

# -------------------- Port pinned to your subnet --------------------
resource "openstack_networking_port_v2" "bastion" {
  name               = "${var.server_name}-port"
  network_id         = local.internal_network_id
  admin_state_up     = true
  security_group_ids = [openstack_networking_secgroup_v2.bastion_sg.id]

  fixed_ip {
    subnet_id = data.openstack_networking_subnet_v2.target.id
    # ip_address = "10.40.144.X" # <-- (optional) set a static IP inside the /20 if you need one
  }

  tags = [for k, v in var.tags : "${k}:${v}"]
}

# -------------------- Instance --------------------
resource "openstack_compute_instance_v2" "bastion" {
  name      = var.server_name
  flavor_name = var.flavor_name
  key_pair    = var.keypair_name
  user_data   = local.user_data
  metadata    = var.tags

  # Attach the pre-created port (ensures we land on the exact subnet)
  network { port = openstack_networking_port_v2.bastion.id }

  # Boot from volume (optional)
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

  image_id = var.attach_volume_boot ? null : data.openstack_images_image_v2.image.id
}

# -------------------- Floating IP (optional) --------------------
resource "openstack_networking_floatingip_v2" "fip" {
  count = var.allocate_fip ? 1 : 0
  pool  = var.external_network_name   # NAME where External=True (e.g., "Vlan127")
}

resource "openstack_networking_floatingip_associate_v2" "fip_assoc" {
  count       = var.allocate_fip ? 1 : 0
  floating_ip = openstack_networking_floatingip_v2.fip[0].address
  port_id     = openstack_networking_port_v2.bastion.id
}

