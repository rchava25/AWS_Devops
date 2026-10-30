module "container_images" {
  source = "../container-images"

  container_image_overrides = var.container_image_overrides
}
