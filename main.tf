provider "google" {
  version = "~> 3.67.0"
  project = var.project
  region  = var.region
  credentials = file("credentials.json")
}

# New resource for the storage bucket our application will use.
resource "google_storage_bucket" "static-site" {
  name     = "csk2021"
  location = "US"

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

resource "google_compute_network" "webserver" {
  name                    = "${var.prefix}-vpc-${var.region}"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "webserver" {
  name          = "${var.prefix}-subnet"
  region        = var.region
  network       = google_compute_network.webserver.self_link
  ip_cidr_range = var.subnet_prefix
}

resource "google_compute_firewall" "http-server" {
  name    = "default-allow-ssh-http"
  network = google_compute_network.webserver.self_link

  allow {
    protocol = "tcp"
    ports    = ["22", "80"]
  }

  // Allow traffic from everywhere to instances with an http-server tag
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server"]
}

resource "google_compute_instance" "webserver" {
  name         = "${var.prefix}-webserver"
  zone         = "${var.region}-b"
  machine_type = var.machine_type

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-1804-lts"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.webserver.self_link
    access_config {
    }
  }

    tags = ["http-server"]

  labels = {
    name = "webserver"
  }
}
resource "null_resource" "git_clone" {
  provisioner "local-exec" {
    command = "git clone https://github.com/sricharankoyalkar/spring-mvc-login.git"
  }
}

data "google_container_engine_versions" "gke_versions" {}

data "google_project" "project" {}

data "google_container_registry_image" "default" {
  name   = "gke-${var.env}"
  region = "eu"
  tag    = "${var.image_tag}"
}
resource "google_compute_network" "gke_network" {
  provider                = "google"
  name                    = "${var.network_name}"
  auto_create_subnetworks = false
}

resource "google_container_cluster" "gke_cluster" {
  provider           = "google-beta"
  min_master_version = "${data.google_container_engine_versions.gke_versions.latest_master_version}"
  name               = "gke-cluster-${var.env}"

  # Using full path instead of just "${google_compute_network.gke_network.name}" to avoid unnecessary updates
  # https://github.com/terraform-providers/terraform-provider-google/issues/1792
  network = "projects/${data.google_project.project.project_id}/global/networks/${google_compute_network.gke_network.name}"

  remove_default_node_pool = true

  addons_config {
    http_load_balancing {
      disabled = false
    }

    kubernetes_dashboard {
      disabled = true
    }
  }

  private_cluster_config {
    master_ipv4_cidr_block = "172.16.0.0/28"
    enable_private_nodes   = true
  }

  # Disable Basic Auth
  master_auth {
    username = ""
    password = ""
  }

  # Kubernetes master's external IP is only accessible from ${var.kubernetes_master_allowed_ip}
  master_authorized_networks_config {
    cidr_blocks = [
      {
        cidr_block = "${var.k8s_master_allowed_ip}/32"
      },
    ]
  }

  # Use ABAC until official Kubernetes plugin supports RBAC
  enable_legacy_abac = "true"

  # Enable alias IP addresses https://cloud.google.com/kubernetes-engine/docs/how-to/alias-ips
  ip_allocation_policy {
    create_subnetwork = true
    subnetwork_name   = "${var.network_name}"
  }

  lifecycle {
    ignore_changes = ["node_pool"]
  }

  node_pool {
    name = "default-pool"
  }
}

resource "google_container_node_pool" "gke_pool" {
  provider   = "google"
  name       = "gke-pool-${var.env}"
  cluster    = "${google_container_cluster.gke_cluster.name}"
  node_count = "${var.node_count}"

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]

    disk_size_gb = 10
    machine_type = "${var.machine_type}"
  }
}

resource "google_cloudbuild_trigger" "build-trigger" {
  trigger_template {
    branch_name = "master"
    repo_name   = "github_csk17k_gcp-vpc-vm"
  }

  build {
    step {
      name = "gcr.io/cloud-builders/gsutil"
      args = ["cp", "gs://mybucket/remotefile.zip", "localfile.zip"]
      timeout = "120s"
    }

    source {
      storage_source {
        bucket = "mybucket"
        object = "source_code.tar.gz"
      }
    }
   
    queue_ttl = "20s"
    logs_bucket = "gs://mybucket/logs"
    secret {
      kms_key_name = "projects/myProject/locations/global/keyRings/keyring-name/cryptoKeys/key-name"
      secret_env = {
        PASSWORD = "ZW5jcnlwdGVkLXBhc3N3b3JkCg=="
      }
    }
    artifacts {
      images = ["gcr.io/$PROJECT_ID/$REPO_NAME:$COMMIT_SHA"]
      objects {
        location = "gs://bucket/path/to/somewhere/"
        paths = ["path"]
      }
    }
    options {
      source_provenance_hash = ["MD5"]
      requested_verify_option = "VERIFIED"
      machine_type = "N1_HIGHCPU_8"
      disk_size_gb = 100
      substitution_option = "ALLOW_LOOSE"
      dynamic_substitutions = true
      log_streaming_option = "STREAM_OFF"
      worker_pool = "pool"
      logging = "LEGACY"
      env = ["ekey = evalue"]
      secret_env = ["secretenv = svalue"]
      volumes {
        name = "v1"
        path = "v1"
      }
    }
  }  
}
