################################################################################
# PROVIDER CONFIGURATION
################################################################################
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.10"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.10"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

################################################################################
# NETWORK LAYER (VPC & SUBNETS)
################################################################################
resource "google_compute_network" "vpc" {
  name                    = "cat-secure-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_compute_subnetwork" "private_subnet" {
  name                     = "cat-subnet-private-us-central1"
  ip_cidr_range            = "10.0.0.0/20" # Node IPs
  region                   = "us-central1"
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = "10.4.0.0/14"
  }

  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "10.8.0.0/20"
  }
}

# Cloud Router & NAT for Outbound Internet Access (Secure Egress)
resource "google_compute_router" "router" {
  name    = "cat-router"
  region  = "us-central1"
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "cat-nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

################################################################################
# SECURITY LAYER (KMS & WAF)
################################################################################
# KMS KeyRing & Key for CMEK
resource "google_kms_key_ring" "cat_keyring" {
  name     = "cat-secure-keyring"
  location = "us-central1"
}

resource "google_kms_crypto_key" "cat_key" {
  name            = "cat-master-key"
  key_ring        = google_kms_key_ring.cat_keyring.id
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = true
  }
}

# Cloud Armor Security Policy
resource "google_compute_security_policy" "cat_waf_policy" {
  name        = "cat-edge-security-policy"
  description = "WAF & Rate Limiting"

  # Rule: SQL Injection Block
  rule {
    action   = "deny(403)"
    priority = "1000"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
      }
    }
  }

  # Rule: XSS Block
  rule {
    action   = "deny(403)"
    priority = "1001"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable')"
      }
    }
  }

  # Rule: Rate Limiting
  rule {
    action   = "rate_based_ban"
    priority = "2000"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      rate_limit_threshold {
        count        = 1000
        interval_sec = 60
      }
      ban_duration_sec = 600
    }
  }

  rule {
    action   = "allow"
    priority = "2147483647"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

################################################################################
# COMPUTE LAYER (GKE PRIVATE CLUSTER)
################################################################################
resource "google_container_cluster" "primary" {
  name     = "cat-secure-cluster"
  location = "us-central1"
  
  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.private_subnet.id
  
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "10.0.0.0/8"
      display_name = "CAT-Corporate-VPN"
    }
    cidr_blocks {
      cidr_block   = "192.168.10.0/24"
      display_name = "Cloud-Build-Private-Pool"
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = true
}

resource "google_container_node_pool" "primary_nodes" {
  name     = "cat-node-pool"
  cluster  = google_container_cluster.primary.id
  location = "us-central1"
  
  node_count = 1

  node_config {
    machine_type = "e2-standard-4"
    
    # Workload Identity & Scopes
    service_account = google_service_account.gke_sa.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    tags = ["gke-node-private"]
  }
  
  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }
}

# Service Account for GKE Nodes
resource "google_service_account" "gke_sa" {
  account_id   = "cat-gke-node-sa"
  display_name = "GKE Node Service Account"
}

################################################################################
# STORAGE LAYER (BUCKET)
################################################################################
resource "google_storage_bucket" "recordings" {
  name          = "cat-recordings-secure-prod"
  location      = "US"
  force_destroy = false

  encryption {
    default_kms_key_name = google_kms_crypto_key.cat_key.id
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = 365
    }
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
  }
}

################################################################################
# CI/CD LAYER (ARTIFACT REGISTRY & PRIVATE POOL)
################################################################################
resource "google_artifact_registry_repository" "cat_repo" {
  location      = "us-central1"
  repository_id = "cat-secure-repo"
  description   = "Docker Repo"
  format        = "DOCKER"
  kms_key_name  = google_kms_crypto_key.cat_key.id
}

# Reserved IP Range for Private Pool Peering
resource "google_compute_global_address" "worker_range" {
  name          = "cat-worker-pool-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24
  network       = google_compute_network.vpc.id
}

# Service Networking Connection
resource "google_service_networking_connection" "worker_peering" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.worker_range.name]
}

resource "google_cloudbuild_worker_pool" "cat_private_pool" {
  name     = "cat-private-pool"
  location = "us-central1"
  
  worker_config {
    disk_size_gb   = 100
    machine_type   = "e2-standard-4"
    no_external_ip = true
  }

  network_config {
    peered_network = google_compute_network.vpc.id
  }

  depends_on = [google_service_networking_connection.worker_peering]
}
