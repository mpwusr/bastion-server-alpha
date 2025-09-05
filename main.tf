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
  cloud  = "mycloud"
  # region = "AUE1"  # uncomment to force region if needed
}

# -------------------- Variables --------------------
variable "server_name"  { type = string, default = "bastion-almalinux9" }
variable "image_name"   { type = string, default = "AlmaLinux-9" }
variable "flavor_name"  { type = string, default = "gp1.micro" }
variable "keypair_name" { type = string }

# If you already have a tenant/internal network, set one of these:
variable "network_id"   { type = string, default = "" }   # internal net UUID
variable "network_name" { type = string, default = "" }   # internal net NAME

# External/public network **NAME** (where External=True) for FIPs + router gw
variable "external_network_name" { type = string }

# Create a tenant network/router automatically (useful when you have none)
variable "create_tenant_network" {
  type    = bool
  default = true
}

# Tenant network settings (used when create_tenant_network=true)
variable "tenant_net_name"        { type = string, default = "bastion-net" }
variable "tenant_subnet_name"     { type = string, default = "bastion-subnet" }
variable "tenant_subnet_cidr"     { type = string, default = "10.42.0.0/24" }
variable "tenant_subnet_gateway"  { type = string, default = null }
variable "dns_nameservers"        { type = list(string), default = ["1.1.1.1","8.8.8.8"] }

# Security / boot
variable "ssh_ingress_cidr"   { type = string, default = "0.0.0.0/0" }
variable "volume_size_gb"     { type = number, default = 20 }
variable "attach_volume_boot" { type = bool,   default = true }

# SSH key: paste text or read from file
variable "admin_pubkey"      { type = string, default = "" }
variable "admin_pubkey_path" { type = string, default = "~/.ssh/id_rsa.pub" }

# Allocate Floating IP? (set false if pool is exhausted)
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

# Resolve external network by NAME (used for FIP and router gw)
data "openstack_networking_network_v2" "external" {
  name = var.external_network_name
}

# Create tenant net/subnet/router if requested
resource "openstack_networking_network_v2" "tenant" {
  count          = var.create_tenant_network ? 1 : 0
  name           = var.tenant_net_name
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "tenant" {
  count           = var.create_tenant_network ? 1 : 0
  name            = var.tenant_subnet_name
  network_id      = openstack_networking_network_v2.tenant[0].id
  cidr            = var.tenant_subnet_cidr
  ip_version      = 4
  gateway_ip      = var.tenant_subnet_gateway
  enable_dhcp     = true
  dns_nameservers = var.dns_nameservers
}

resource "openstack_networking_router_v2" "tenant" {
  count               = var.create_tenant_network ? 1 : 0
  name                = "${var.tenant_net_name}-router"
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.external.id
}

resource "openstack_networking_router_interface_v2" "tenant" {
  count     = var.create_tenant_network ? 1 : 0
  router_id = openstack_networking_router_v2.tenant[0].id
  subnet_id = openstack_networking_subnet_v2.tenant[0].id
}

# If not creating, resolve an existing internal network by name/id
data "openstack_networking_network_v2" "internal_existing" {
  count = var.create_tenant_network ? 0 : 1
  name  = (var.network_name != "" ? var.network_name : null)
  id    = (var.network_name == "" && var.network_id != "" ? var.network_id : null)
}

# Effective internal network id we’ll attach to
locals {
  internal_network_id = var.create_tenant_network
    ? openstack_networking_network_v2.tenant[0].id
    : data.openstack_networking_network_v2.internal_existing[0].id
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

# -------------------- Instance --------------------
resource "openstack_compute_instance_v2" "bastion" {
  name            = var.server_name
  flavor_name     = var.flavor_name
  key_pair        = var.keypair_name
  security_groups = [openstack_networking_secgroup_v2.bastion_sg.name]
  user_data       = local.user_data
  metadata        = var.tags

  # Attach to the tenant/internal network
  network { uuid = local.internal_network_id }

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

  # Ensure router interface exists before boot when creating tenant net
  depends_on = [openstack_networking_router_interface_v2.tenant]
}

# -------------------- Floating IP (optional) --------------------
resource "openstack_networking_floatingip_v2" "fip" {
  count = var.allocate_fip ? 1 : 0
  pool  = var.external_network_name   # NAME where External=True (e.g., "Vlan127")
}

resource "openstack_networking_floatingip_associate_v2" "fip_assoc" {
  count       = var.allocate_fip ? 1 : 0
  floating_ip = openstack_networking_floatingip_v2.fip[0].address
  port_id     = openstack_compute_instance_v2.bastion.network[0].port
}
