resource "aws_ecr_repository" "services" {
  for_each = toset(var.services)

  name                 = each.key
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  lifecycle {
    prevent_destroy = false
  }
}

# Lifecycle rules:
#   1. Keep the most recent N immutable env build tags
#      ({qa,uat,prod,dev}-YYYYMMDD-<sha7>). We prefix-match on "{env}-2"
#      (the leading "2" of the date) so the mutable "*-latest" pointers
#      are NOT swept by this rule. Safe until year 3000.
#   2. Keep a generous number of semver release tags (v*). These are only
#      ever cut on releases, so a high count is effectively "forever".
#   3. "*-latest" pointer tags are not matched by any rule and therefore
#      never expire.
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = toset(var.services)
  repository = aws_ecr_repository.services[each.key].name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 immutable env build tags (env-YYYYMMDD-sha7)"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["qa-2", "uat-2", "prod-2", "dev-2"] # Note: this will stop working at year 3000
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 100 semver release tags (v*)"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]
          countType     = "imageCountMoreThan"
          countNumber   = 100
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
