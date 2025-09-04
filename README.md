# Bastion AlmaLinux 9 (Terraform on OpenStack)

This Terraform module provisions a **bastion host** (jumpbox) running AlmaLinux 9 (CLI only) in OpenStack.
The bastion is designed to manage multiple Kubernetes clusters by installing common CLI tools like **kubectl, helm, k9s, kubectx, kubens, and the OpenStack client** via cloud-init.

---

## Prerequisites

* OpenStack project/tenant with network and floating IP access
* Terraform `>= 1.4`
* OpenStack Terraform provider `>= 1.54`
* Your OpenStack credentials:

  * Either via environment variables (`OS_AUTH_URL`, `OS_USERNAME`, etc.)
  * Or via a `clouds.yaml` config and `cloud` parameter
* An existing SSH keypair uploaded to OpenStack

---

## Variables

| Variable              | Description                                     | Default              |
| --------------------- | ----------------------------------------------- | -------------------- |
| `server_name`         | Bastion server name                             | `bastion-almalinux9` |
| `image_name`          | AlmaLinux 9 image name in OpenStack             | `AlmaLinux-9`        |
| `flavor_name`         | OpenStack flavor                                | `m1.small`           |
| `keypair_name`        | Name of uploaded OpenStack keypair              | **required**         |
| `network_id`          | ID of internal/project network                  | **required**         |
| `subnet_id`           | Subnet ID for port creation                     | **required**         |
| `external_network_id` | ID of external/public network (for floating IP) | **required**         |
| `ssh_ingress_cidr`    | CIDR allowed SSH access                         | `0.0.0.0/0`          |
| `volume_size_gb`      | Root volume size (GB)                           | `20`                 |
| `attach_volume_boot`  | Whether to boot from volume                     | `true`               |
| `tags`                | Map of tags for the server                      | `{}`                 |
| `admin_pubkey`        | Public SSH key for `admin` user                 | none                 |

---

## Usage

1. **Clone this repo** or copy the `main.tf` and `README.md` files:

   ```bash
   git clone <your-repo-url>
   cd bastion-terraform
   ```

2. **Export your OpenStack credentials** (if not using `clouds.yaml`):

   ```bash
   export OS_AUTH_URL=https://openstack.example.com:5000/v3
   export OS_PROJECT_NAME=myproject
   export OS_USERNAME=myuser
   export OS_PASSWORD=mypassword
   export OS_REGION_NAME=RegionOne
   ```

3. **Initialize Terraform**:

   ```bash
   terraform init
   ```

4. **Create a `terraform.tfvars` file** (or pass variables via CLI):

   ```hcl
   keypair_name        = "my-keypair"
   network_id          = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   subnet_id           = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   external_network_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   ssh_ingress_cidr    = "203.0.113.45/32"   # your public IP
   admin_pubkey        = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ..."
   ```

5. **Plan and apply**:

   ```bash
   terraform plan
   terraform apply
   ```

6. **Connect to the bastion**:

   ```bash
   ssh admin@<floating_ip>
   ```

   From here you can run:

   * `kubectl` to manage your clusters (add kubeconfigs in `~/.kube/config`)
   * `helm`, `k9s`, `kubectx`, `kubens` for easier cluster management
   * `openstack` CLI for cloud operations

---

## Cleanup

When finished, destroy the bastion:

```bash
terraform destroy
```

---

⚠️ **Security Note:**
Restrict `ssh_ingress_cidr` to your trusted IP ranges, not `0.0.0.0/0`. Also, rotate keys regularly and disable password authentication (already enforced in cloud-init).

---

Would you like me to also include the **`cloud-init` YAML** snippet in this README (so you can see exactly what tools get installed), or just keep it hidden in `main.tf`?
