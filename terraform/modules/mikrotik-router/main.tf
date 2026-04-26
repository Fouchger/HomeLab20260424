# ==============================================================================
# File: terraform/modules/mikrotik-router/main.tf
# Purpose:
#   Terraform integration point for MikroTik RouterOS configuration orchestration.
# Notes:
#   - Terraform does not hold router secrets.
#   - Task remains the operator entrypoint and resolves secrets through the repo
#     standard encrypted dotenv workflow.
# ==============================================================================

resource "null_resource" "mikrotik_router_plan" {
  triggers = {
    router_profile = var.router_profile
    apply_mode     = var.apply_mode
  }

  provisioner "local-exec" {
    working_dir = var.repository_root
    command     = var.apply_mode ? "task router:apply" : "task router:plan"
  }
}
