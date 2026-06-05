terraform {
required_providers {
aws = {
source = "hashicorp/aws"
version = "~> 5.0"
 }
}
required_version = ">= 1.6"
backend "s3" {
bucket = "brianne-terraform-state-2026"
key = "project-3/terraform.tfstate"
region = "us-east-1"
}
}
provider "aws" {
    region = "us-east-1"
}