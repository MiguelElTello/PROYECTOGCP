################################################################################
# CONFIGURACIÓN GENERAL
################################################################################
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 5.10" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 5.10" }
  }
}

provider "google" {
  project = var.project_id
  region  = "europe-southwest1"
}

provider "google-beta" {
  project = var.project_id
  region  = "europe-southwest1"
}

################################################################################
# RED Y VPN (CONECTIVIDAD HÍBRIDA)
################################################################################
resource "google_compute_network" "vpc" {
  name                    = "cat-secure-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"
}

resource "google_compute_subnetwork" "private_subnet" {
  name                     = "cat-subnet-private-madrid"
  ip_cidr_range            = "10.0.0.0/20"
  region                   = "europe-southwest1"
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  secondary_ip_range { range_name = "pods-range", ip_cidr_range = "10.4.0.0/14" }
  secondary_ip_range { range_name = "services-range", ip_cidr_range = "10.8.0.0/20" }
}

resource "google_compute_router" "router" {
  name    = "cat-router-madrid"
  region  = "europe-southwest1"
  network = google_compute_network.vpc.id
  bgp { asn = 64514 }
}

resource "google_compute_router_nat" "nat" {
  name                               = "cat-nat-madrid"
  router                             = google_compute_router.router.name
  region                             = "europe-southwest1"
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# --- VPN HA Configuration ---
resource "google_compute_ha_vpn_gateway" "cat_vpn_gateway" {
  name    = "cat-ha-vpn-gw"
  network = google_compute_network.vpc.id
  region  = "europe-southwest1"
}

resource "google_compute_external_vpn_gateway" "cat_onprem_gateway" {
  name            = "cat-onprem-gw"
  redundancy_type = "SINGLE_IP_INTERNALLY_REDUNDANT"
  interface {
    id         = 0
    ip_address = "203.0.113.15" # IP Pública Oficina CAT
  }
}

resource "google_compute_vpn_tunnel" "tunnel1" {
  name                  = "cat-vpn-tunnel-1"
  region                = "europe-southwest1"
  vpn_gateway           = google_compute_ha_vpn_gateway.cat_vpn_gateway.id
  peer_external_gateway = google_compute_external_vpn_gateway.cat_onprem_gateway.id
  peer_external_gateway_interface = 0
  shared_secret         = "secret-key-placeholder"
  router                = google_compute_router.router.id
  vpn_gateway_interface = 0
}

################################################################################
# SEGURIDAD Y CÓMPUTO (GKE & KMS)
################################################################################
resource "google_kms_key_ring" "cat_keyring" {
  name     = "cat-keyring-madrid"
  location = "europe-southwest1"
}

resource "google_kms_crypto_key" "cat_key" {
  name            = "cat-master-key"
  key_ring        = google_kms_key_ring.cat_keyring.id
  rotation_period = "7776000s"
}

resource "google_container_cluster" "primary" {
  name     = "cat-secure-cluster-madrid"
  location = "europe-southwest1"
  network  = google_compute_network.vpc.id
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
    cidr_blocks { cidr_block = "192.168.10.0/24", display_name = "CAT-VPN" }
    cidr_blocks { cidr_block = "10.0.0.0/8", display_name = "VPC-Internal" }
  }

  workload_identity_config { workload_pool = "${var.project_id}.svc.id.goog" }
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = true
}

resource "google_container_node_pool" "primary_nodes" {
  name     = "cat-nodes-madrid"
  cluster  = google_container_cluster.primary.id
  location = "europe-southwest1"
  node_count = 1
  node_config {
    machine_type = "e2-standard-4"
    service_account = google_service_account.gke_sa.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    workload_metadata_config { mode = "GKE_METADATA" }
    tags = ["gke-node-private"]
  }
}

resource "google_service_account" "gke_sa" {
  account_id = "cat-gke-node-sa"
}

################################################################################
# ALMACENAMIENTO Y CI/CD
################################################################################
resource "google_storage_bucket" "recordings" {
  name          = "cat-recordings-madrid-prod"
  location      = "europe-southwest1"
  encryption { default_kms_key_name = google_kms_crypto_key.cat_key.id }
}

resource "google_artifact_registry_repository" "cat_repo" {
  location      = "europe-southwest1"
  repository_id = "cat-secure-repo"
  format        = "DOCKER"
  kms_key_name  = google_kms_crypto_key.cat_key.id
}

resource "google_cloudbuild_worker_pool" "cat_private_pool" {
  name     = "cat-build-pool-madrid"
  location = "europe-southwest1"
  worker_config {
    disk_size_gb   = 100
    machine_type   = "e2-standard-4"
    no_external_ip = true
  }
}
