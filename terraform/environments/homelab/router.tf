# ==============================================================================
# File: terraform/environments/homelab/router.tf
# Purpose:
#   Homelab environment integration for MikroTik RouterOS orchestration.
# Notes:
#   - Defaults to plan mode for safety.
#   - Set router_apply_mode=true only for an intentional Terraform-triggered apply.
# ==============================================================================

module "mikrotik_router" {
  source = "../../modules/mikrotik-router"

  repository_root = "../../.."
  router_profile  = "homelab"
  apply_mode      = var.router_apply_mode
}
