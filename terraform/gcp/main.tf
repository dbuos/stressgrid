terraform {
  required_version = ">= 0.12.0"
  required_providers {
    external = ">= 1.2.0"
    google   = ">= 2.14.0"
  }
}

variable region {
  type = "string"
}

variable zone {
  type = "string"
}

variable project {
  type = "string"
}

variable image_project {
  type    = "string"
  default = "stressgrid"
}

variable network {
  type    = "string"
  default = "default"
}

variable capacity {
  type    = "string"
  default = "1"
}

variable generator_machine_type {
  type    = "string"
  default = "n1-standard-4"
}

variable coordinator_machine_type {
  type    = "string"
  default = "n1-standard-1"
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
}

data "external" "my_ip" {
  program = ["curl", "https://api.ipify.org?format=json"]
}

data "google_compute_network" "stressgrid_network" {
  name = var.network
}

data "google_compute_image" "generator_latest" {
  family  = "stressgrid-generator"
  project = var.image_project
}

data "google_compute_image" "coordinator_latest" {
  family  = "stressgrid-coordinator"
  project = var.image_project
}

resource "google_compute_firewall" "coordinator_management" {
  name    = "coordinator-management"
  network = "${data.google_compute_network.stressgrid_network.self_link}"

  allow {
    protocol = "tcp"
    ports    = ["8000"]
  }

  source_ranges = ["${data.external.my_ip.result.ip}/32"]
  target_tags   = ["coordinator"]
}

resource "google_compute_firewall" "coordinator_generator" {
  name    = "coordinator-generator"
  network = "${data.google_compute_network.stressgrid_network.self_link}"

  allow {
    protocol = "tcp"
    ports    = ["9696"]
  }

  source_tags = ["generator"]
  target_tags = ["coordinator"]
}

resource "google_compute_instance" "coordinator" {
  name         = "stressgrid-coordinator"
  machine_type = var.coordinator_machine_type

  boot_disk {
    initialize_params {
      image = data.google_compute_image.coordinator_latest.self_link
    }
  }

  network_interface {
    network = data.google_compute_network.stressgrid_network.self_link

    access_config {
    }
  }

  tags = ["coordinator"]
}

resource "google_compute_instance_template" "generator" {
  name         = "stressgrid-generator"
  machine_type = var.generator_machine_type

  disk {
    source_image = data.google_compute_image.generator_latest.self_link
    boot         = true
  }

  network_interface {
    network = data.google_compute_network.stressgrid_network.self_link

    access_config {
    }
  }

  metadata_startup_script = templatefile("${path.module}/../generator_init.sh", { coordinator_dns = google_compute_instance.coordinator.network_interface.0.network_ip })

  tags = ["generator"]
}

resource "google_compute_instance_group_manager" "generator" {
  name = "stressgrid-generator"

  base_instance_name = "stressgrid-generator"

  version {
    instance_template  = google_compute_instance_template.generator.self_link
  }

  target_size = var.capacity
}

output "coordinator_url" {
  value = "http://${google_compute_instance.coordinator.network_interface.0.access_config.0.nat_ip}:8000"
}

 