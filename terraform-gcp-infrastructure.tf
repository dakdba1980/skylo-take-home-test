# main.tf - GCP Infrastructure for Web Application Migration

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.0"
}

# Configure the Google Cloud Provider
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Variables
variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP Zone"
  type        = string
  default     = "us-central1-a"
}

variable "environment" {
  description = "Environment (dev, staging, prod)"
  type        = string
  default     = "prod"
}

# VPC Network
resource "google_compute_network" "main_vpc" {
  name                    = "${var.environment}-vpc"
  auto_create_subnetworks = false
  routing_mode           = "GLOBAL"
}

# Subnet for GKE
resource "google_compute_subnetwork" "gke_subnet" {
  name          = "${var.environment}-gke-subnet"
  ip_cidr_range = "10.0.0.0/16"
  region        = var.region
  network       = google_compute_network.main_vpc.id
  
  secondary_ip_range {
    range_name    = "pod-range"
    ip_cidr_range = "10.1.0.0/16"
  }
  
  secondary_ip_range {
    range_name    = "service-range"
    ip_cidr_range = "10.2.0.0/16"
  }
  
  private_ip_google_access = true
}

# Cloud NAT for outbound internet access
resource "google_compute_router" "main_router" {
  name    = "${var.environment}-router"
  region  = var.region
  network = google_compute_network.main_vpc.id
}

resource "google_compute_router_nat" "main_nat" {
  name                               = "${var.environment}-nat"
  router                            = google_compute_router.main_router.name
  region                            = var.region
  nat_ip_allocate_option            = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# GKE Cluster
resource "google_container_cluster" "primary" {
  name     = "${var.environment}-gke-cluster"
  location = var.region
  
  # Remove default node pool
  remove_default_node_pool = true
  initial_node_count       = 1
  
  network    = google_compute_network.main_vpc.name
  subnetwork = google_compute_subnetwork.gke_subnet.name
  
  # Private cluster configuration
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
    
    master_global_access_config {
      enabled = true
    }
  }
  
  # IP allocation policy for VPC-native networking
  ip_allocation_policy {
    cluster_secondary_range_name  = "pod-range"
    services_secondary_range_name = "service-range"
  }
  
  # Enable network policy
  network_policy {
    enabled = true
  }
  
  # Enable Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }
  
  # Binary Authorization
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }
  
  # Release channel for automatic updates
  release_channel {
    channel = "STABLE"
  }
  
  # Monitoring and logging
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
  
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
}

# GKE Node Pool
resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.environment}-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary.name
  node_count = 2
  
  # Auto-scaling configuration
  autoscaling {
    min_node_count = 1
    max_node_count = 10
  }
  
  # Node configuration
  node_config {
    preemptible  = false
    machine_type = "e2-standard-2"
    
    # Google-recommended OS image
    image_type = "COS_CONTAINERD"
    
    # OAuth scopes
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
    
    # Enable Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    
    # Labels for cost tracking
    labels = {
      environment = var.environment
      team        = "platform"
    }
    
    # Disk configuration
    disk_size_gb = 50
    disk_type    = "pd-standard"
    
    # Security configuration
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
  
  # Update strategy
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
  
  # Node management
  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# Cloud SQL Instance
resource "google_sql_database_instance" "main" {
  name             = "${var.environment}-mysql-instance"
  database_version = "MYSQL_8_0"
  region          = var.region
  
  settings {
    tier              = "db-n1-standard-2"
    availability_type = "REGIONAL"
    disk_type         = "PD_SSD"
    disk_size         = 100
    disk_autoresize   = true
    
    # Backup configuration
    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
      backup_retention_settings {
        retained_backups = 7
      }
    }
    
    # IP configuration
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main_vpc.id
      require_ssl     = true
    }
    
    # Maintenance window
    maintenance_window {
      day          = 7
      hour         = 3
      update_track = "stable"
    }
    
    # Database flags for optimization
    database_flags {
      name  = "innodb_buffer_pool_size"
      value = "1073741824"  # 1GB
    }
    
    # Labels
    user_labels = {
      environment = var.environment
      team        = "platform"
    }
  }
  
  depends_on = [google_service_networking_connection.private_vpc_connection]
}

# Private VPC connection for Cloud SQL
resource "google_compute_global_address" "private_ip_address" {
  name          = "private-ip-address"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main_vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

# Cloud SQL Database
resource "google_sql_database" "main_db" {
  name     = "webapp_db"
  instance = google_sql_database_instance.main.name
}

# Cloud SQL User
resource "google_sql_user" "main_user" {
  name     = "webapp_user"
  instance = google_sql_database_instance.main.name
  password = random_password.db_password.result
}

resource "random_password" "db_password" {
  length  = 16
  special = true
}

# Cloud Storage Buckets
resource "google_storage_bucket" "static_assets" {
  name          = "${var.project_id}-${var.environment}-static-assets"
  location      = "US"
  force_destroy = true
  
  uniform_bucket_level_access = true
  
  versioning {
    enabled = true
  }
  
  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }
  
  cors {
    origin          = ["*"]
    method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
    response_header = ["*"]
    max_age_seconds = 3600
  }
}

resource "google_storage_bucket" "data_lake" {
  name          = "${var.project_id}-${var.environment}-data-lake"
  location      = var.region
  force_destroy = true
  
  uniform_bucket_level_access = true
  
  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
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

# BigQuery Dataset
resource "google_bigquery_dataset" "analytics" {
  dataset_id                  = "${var.environment}_analytics"
  friendly_name               = "Analytics Dataset"
  description                 = "Dataset for analytics and reporting"
  location                    = var.region
  default_table_expiration_ms = 2592000000  # 30 days
  
  labels = {
    environment = var.environment
    team        = "data"
  }
}

# Load Balancer
resource "google_compute_global_address" "default" {
  name = "${var.environment}-lb-ip"
}

# SSL Certificate
resource "google_compute_managed_ssl_certificate" "default" {
  name = "${var.environment}-ssl-cert"
  
  managed {
    domains = ["${var.environment}.example.com"]
  }
}

# HTTP(S) Load Balancer
resource "google_compute_url_map" "default" {
  name            = "${var.environment}-url-map"
  default_service = google_compute_backend_service.default.id
  
  host_rule {
    hosts        = ["${var.environment}.example.com"]
    path_matcher = "allpaths"
  }
  
  path_matcher {
    name            = "allpaths"
    default_service = google_compute_backend_service.default.id
    
    path_rule {
      paths   = ["/api/*"]
      service = google_compute_backend_service.api.id
    }
    
    path_rule {
      paths   = ["/*"]
      service = google_compute_backend_service.frontend.id
    }
  }
}

resource "google_compute_target_https_proxy" "default" {
  name             = "${var.environment}-https-proxy"
  url_map          = google_compute_url_map.default.id
  ssl_certificates = [google_compute_managed_ssl_certificate.default.id]
}

resource "google_compute_global_forwarding_rule" "default" {
  name       = "${var.environment}-forwarding-rule"
  target     = google_compute_target_https_proxy.default.id
  port_range = "443"
  ip_address = google_compute_global_address.default.id
}

# Backend Services (placeholder - actual NEGs created by GKE Ingress)
resource "google_compute_backend_service" "default" {
  name        = "${var.environment}-backend-service"
  protocol    = "HTTP"
  timeout_sec = 30
  
  health_checks = [google_compute_health_check.default.id]
}

resource "google_compute_backend_service" "api" {
  name        = "${var.environment}-api-backend"
  protocol    = "HTTP"
  timeout_sec = 30
  
  health_checks = [google_compute_health_check.api.id]
}

resource "google_compute_backend_service" "frontend" {
  name        = "${var.environment}-frontend-backend"
  protocol    = "HTTP"
  timeout_sec = 10
  
  health_checks = [google_compute_health_check.frontend.id]
}

# Health Checks
resource "google_compute_health_check" "default" {
  name = "${var.environment}-health-check"
  
  http_health_check {
    request_path = "/health"
    port         = 8080
  }
}

resource "google_compute_health_check" "api" {
  name = "${var.environment}-api-health-check"
  
  http_health_check {
    request_path = "/api/health"
    port         = 8080
  }
}

resource "google_compute_health_check" "frontend" {
  name = "${var.environment}-frontend-health-check"
  
  http_health_check {
    request_path = "/"
    port         = 80
  }
}

# Cloud CDN
resource "google_compute_backend_bucket" "static_assets" {
  name        = "${var.environment}-static-backend"
  bucket_name = google_storage_bucket.static_assets.name
  enable_cdn  = true
  
  cdn_policy {
    cache_mode                   = "CACHE_ALL_STATIC"
    default_ttl                  = 3600
    max_ttl                      = 86400
    negative_caching             = true
    serve_while_stale            = 86400
    cache_key_policy {
      include_host         = true
      include_protocol     = true
      include_query_string = false
    }
  }
}

# IAM Service Account for Workload Identity
resource "google_service_account" "gke_workload" {
  account_id   = "${var.environment}-gke-workload"
  display_name = "GKE Workload Identity Service Account"
}

# Grant necessary permissions to the service account
resource "google_project_iam_member" "gke_workload_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.gke_workload.email}"
}

resource "google_project_iam_member" "gke_workload_storage" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.gke_workload.email}"
}

resource "google_project_iam_member" "gke_workload_bigquery" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.gke_workload.email}"
}

# Enable required APIs
resource "google_project_service" "required_apis" {
  for_each = toset([
    "container.googleapis.com",
    "compute.googleapis.com",
    "sql-component.googleapis.com",
    "sqladmin.googleapis.com",
    "storage-component.googleapis.com",
    "bigquery.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "binaryauthorization.googleapis.com"
  ])
  
  project = var.project_id
  service = each.value
  
  disable_dependent_services = true
}

# Outputs
output "cluster_name" {
  description = "GKE cluster name"
  value       = google_container_cluster.primary.name
}

output "cluster_location" {
  description = "GKE cluster location"
  value       = google_container_cluster.primary.location
}

output "database_connection_name" {
  description = "Cloud SQL connection name"
  value       = google_sql_database_instance.main.connection_name
}

output "load_balancer_ip" {
  description = "Load balancer IP address"
  value       = google_compute_global_address.default.address
}

output "static_assets_bucket" {
  description = "Static assets bucket name"
  value       = google_storage_bucket.static_assets.name
}

output "service_account_email" {
  description = "Workload Identity service account email"
  value       = google_service_account.gke_workload.email
}