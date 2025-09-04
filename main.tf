terraform {
  required_version = ">= 1.4.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = ">= 1.54.1"
    }
  }
}

# ---- Provider ----
# Either export OS_* env vars or set cloud name if using clouds.yaml
provider "openstack" {
  # cloud = var.os_cloud   # uncomment if you use clouds.yaml and pass var.os_cloud
}

# ---- Inputs ----
variable "server_name"        { type = string  default = "bastion-almalinux9" }
variable "image_name"         { type = string  default = "AlmaLinux-9" } # adjust to exact image name in your cloud
variable "flavor_name"        { type = string  default = "m1.small" }
variable "keypair_name"       { type = string }
variable "network_id"         { type = string }        # tenant/internal network ID
variable "subnet_id"          { type = string }        # for port creation if needed
variable "external_network_id"{ type = string }        # public / floating IP pool
variable "ssh_ingress_cidr"   { type = string  default = "0.0.0.0/0" } # replace with your IP/cidr
variable "volume_size_gb"     { type = number  default = 20 }
variable "attach_volume_boot" { type = bool    default = true }
variable "tags"               { type = map(string) default = {} }

# Put your public SSH key here if you want cloud-init to provision it for the admin user as well.
variable "admin_pubkey" {
  type        = string
  description = "
