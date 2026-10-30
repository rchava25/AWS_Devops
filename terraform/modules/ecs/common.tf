resource "aws_kms_key" "cmk" {
  description             = "${var.environment_name} CMK"
  deletion_window_in_days = 7
}
