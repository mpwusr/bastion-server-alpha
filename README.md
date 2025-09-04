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

# Bastion AlmaLinux 9 on OpenStack with Terraform

This project provisions a **bastion host** (jumpbox) running AlmaLinux 9 (CLI) in OpenStack using Terraform.  
The bastion is designed to manage multiple Kubernetes clusters, with cloud-init installing common tools like:

- `kubectl`, `helm`, `k9s`, `kubectx`, `kubens`
- `openstack` CLI
- `tmux`, `jq`, and other admin utilities

---

## Prerequisites

- VPN connected to your corporate network (to reach OpenStack APIs).
- Okta SSO access to Horizon (OpenStack Dashboard).
- Terraform `>= 1.4`
- OpenStack Terraform provider `>= 1.54`
- An OpenStack project/tenant with networking and floating IPs available.
- An SSH keypair uploaded to OpenStack.

---

## Step 1. Log in to Horizon via Okta

1. Open your Horizon URL (example):  
   `https://horizon.example.com`
2. Choose **Okta** as the login method and sign in.
3. In the top bar, switch to the **Project** where you want the bastion created.

---

## Step 2. Create an Application Credential

1. Navigate to **Identity → Application Credentials**.
2. Click **Create Application Credential**.
3. Fill the form:
   - **Name:** `terraform-bastion`
   - **Description:** `Terraform provisioning from my laptop`
   - **Secret:** leave blank (auto-generate)
   - **Expires At:** set if required (e.g., +90 days)
   - **Roles:** select at least your project’s role (often `member`)
   - **Unrestricted:** enable if allowed for Terraform provisioning
4. Click **Create** and download the credential file if Horizon offers it.  
   If not, copy the displayed **ID** and **Secret**.

---

## Step 3. Save `clouds.yaml`

Create `~/.config/openstack/clouds.yaml` (if it doesn’t exist):

```yaml
clouds:
  mycloud:
    auth:
      auth_url: https://openstack.example.com:5000/v3
      application_credential_id: "APP_CRED_ID_FROM_HORIZON"
      application_credential_secret: "APP_CRED_SECRET_FROM_HORIZON"
    region_name: "RegionOne"
    interface: "public"        # or "internal" if required over VPN
    identity_api_version: 3
````

⚠️ **Do not commit this file to Git.** It contains secrets.

---

## Step 4. Test the OpenStack CLI

Export the cloud name:

```bash
export OS_CLOUD=mycloud
```

Test your credential:

```bash
openstack token issue
openstack server list
```

If you see a token and server list (even if empty), your credential works.

---

## Step 5. Configure Terraform

In `main.tf`:

```hcl
provider "openstack" {
  cloud = "mycloud"   # matches the clouds.yaml entry
}
```

Run:

```bash
terraform init
terraform plan
terraform apply
```

Terraform will provision the AlmaLinux 9 bastion with a floating IP and install admin tools.

---

## Step 6. Connect to the Bastion

```bash
ssh admin@<floating_ip>
```

Once inside, you’ll have:

* `kubectl`, `helm`, `k9s` for managing clusters
* `openstack` CLI for cloud operations

Upload your kubeconfigs into `~/.kube/config` to use `kubectl`.

---

## Step 7. Rotate or Revoke Credentials

* **Rotate:** Create a new Application Credential in Horizon, update `clouds.yaml`, then delete the old one.
* **Revoke:** Delete the Application Credential in Horizon to immediately invalidate it.
* **Expire:** If you set `Expires At`, you’ll need to generate a new one before it lapses.

---

## Troubleshooting

* **401 Unauthorized:** Wrong ID/Secret or expired credential → recreate the Application Credential.
* **Cannot reach Keystone:** VPN not connected or wrong `auth_url`.
* **TLS/CA errors:** Add `cacert:` and `verify:` fields in `clouds.yaml` if your org uses a custom CA.
* **Interface mismatch:** Use `interface: internal` if your org blocks public endpoints on VPN.
* **403 Forbidden on resource create:** Role is too limited → recreate with correct roles.

---

## Cleanup

To remove the bastion:

```bash
terraform destroy
```

---

## Security Notes

* Restrict `ssh_ingress_cidr` in `main.tf` to your trusted IP(s), not `0.0.0.0/0`.
* Rotate your Application Credentials regularly.
* Never commit `clouds.yaml` or secrets to Git.

