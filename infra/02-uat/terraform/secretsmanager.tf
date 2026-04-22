# Secrets Manager entries for each backend service.
# ExternalSecrets pulls these into k8s Secrets (uat/<service>-env).

locals {
  common_secret_values = {
    DATABASE_HOST     = module.db.db_instance_address
    DATABASE_PORT     = "3306"
    DATABASE_NAME     = "uatdb"
    DATABASE_USER     = "dbmaster"
    DATABASE_PASSWORD = var.db_password
    JWT_SECRET        = var.jwt_secret
  }

  services = ["auth-service", "score-service", "session-service"]
}

resource "aws_secretsmanager_secret" "service" {
  for_each = toset(local.services)

  name                    = "uat/${each.key}"
  description             = "Env vars for ${each.key} in UAT"
  recovery_window_in_days = 0 # allow immediate delete during dev

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "service" {
  for_each = toset(local.services)

  secret_id     = aws_secretsmanager_secret.service[each.key].id
  secret_string = jsonencode(local.common_secret_values)
}
