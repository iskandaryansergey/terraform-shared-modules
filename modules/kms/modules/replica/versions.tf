terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # The same range as the root module, which compiles what this one creates.
      version = ">= 5.73.0, < 6.0.0"
    }
  }
}
