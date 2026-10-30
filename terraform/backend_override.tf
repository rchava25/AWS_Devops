terraform {
  backend "s3" {
    bucket = "workshop-team-stack-terraformrunnerterraformstateb-widrqb8dzcq4"
    key    = "terraform.tfstate"
    region = "us-west-2"
  }
}
