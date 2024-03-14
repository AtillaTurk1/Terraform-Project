# Google Cloud sağlayıcısını belirtelim
terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "5.19.0"
    }
  }
}

provider "google" {
  project = "terraform-project-416712"
  region  = "europe-west1"
  credentials = "cred.json"
}

# VPC network oluşturalım
resource "google_compute_network" "my-network" {
  name = "my-network"
  auto_create_subnetworks = false
}

# Subnet oluşturalım
resource "google_compute_subnetwork" "my-subnet" {
  name = "my-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region = "europe-west1"
  network = google_compute_network.my-network.id
}

# VPC networkte Cloud Router ve NAT Gateway oluşturalım
resource "google_compute_router" "router" {
  name    = "my-router"
  region  = google_compute_subnetwork.my-subnet.region
  network = google_compute_network.my-network.id

  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "nat" {
  name                               = "my-router-nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Manage Instance Group İçin Template Oluşturalım
resource "google_compute_instance_template" "default" {
  name = "backend-template"
  disk {
    auto_delete  = true
    boot         = true
    device_name  = "persistent-disk-0"
    mode         = "READ_WRITE"
    source_image = "projects/debian-cloud/global/images/family/debian-11"
    type         = "PERSISTENT"
  }
  labels = {
    managed-by-cnrm = "true"
  }
  machine_type = "e2-micro"
  metadata = {
    startup-script = "#! /bin/bash\n sudo apt-get update\n  sudo apt-get install apache2 -y\n  sudo a2ensite default-ssl\n  sudo a2enmod ssl\n  vm_hostname=\"$(curl -H \"Metadata-Flavor:Google\" \\\n   http://169.254.169.254/computeMetadata/v1/instance/name)\"\n   sudo echo \"HOS GELDINIZ  VM HOSTNAME: $vm_hostname\" | \\\n   tee /var/www/html/index.html\n   sudo systemctl restart apache2"
  }
  network_interface {
  network = google_compute_network.my-network.id
  subnetwork = google_compute_subnetwork.my-subnet.id
  }
  region = "europe-west1"
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }
}
# Manage Instance Group Oluşturalım
resource "google_compute_instance_group_manager" "default" {
  name = "instance-group"
  zone = "europe-west1-d"
  named_port {
    name = "http"
    port = 80
  }
  named_port {
    name = "ssh"
    port = 22
  }
  named_port {
    name = "tcp"
    port = 5432
  }
  named_port {
    name = "tcp"
    port = 3307
  }
  named_port {
    name = "tcp"
    port = 3306
  }
  version {
    instance_template = google_compute_instance_template.default.id
    name              = "primary"
  }
  base_instance_name = "vm"
  target_size        = 2
}

# Manage Instance İçin Autoscaler Oluşturalım
resource "google_compute_autoscaler" "default" {
  name   = "my-autoscaler"
  zone   = "europe-west1-d"
  target = google_compute_instance_group_manager.default.id

  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 2
    cooldown_period = 60

    cpu_utilization {
      target = 0.5
    }
  }
}

# Load balancer ve ssh bağlantılarını sağlamak için güvenlik duvarı kuralları ekleyelim
resource "google_compute_firewall" "default" {
  name          = "fw-allow-health-check"
  direction     = "INGRESS"
  network       = google_compute_network.my-network.id
  priority      = 1000
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "35.235.240.0/20"]
  allow {
    ports    = ["80"]
    protocol = "tcp"
  }
  allow {
    ports    = ["22"]
    protocol = "tcp"
}
  allow {
    ports    = ["5432"]
    protocol = "tcp"
}
  allow {
    ports    = ["3307"]
    protocol = "tcp"
}
  allow {
    ports    = ["3306"]
    protocol = "tcp"
}
}
# Http Load balancing için IPV4 adresi tanımlayalım
resource "google_compute_global_address" "default" {
  name       = "lb-ipv4-1"
  ip_version = "IPV4"
}
# Load balancing için Health Check ayarlayalım
resource "google_compute_health_check" "default" {
  name               = "http-basic-check"
  check_interval_sec = 5
  healthy_threshold  = 2
  http_health_check {
    port               = 80
    port_specification = "USE_FIXED_PORT"
    proxy_header       = "NONE"
    request_path       = "/"
  }
  timeout_sec         = 5
  unhealthy_threshold = 2
}

# Load balancing backend servisi oluşturalım
resource "google_compute_backend_service" "default" {
  name                            = "web-backend-service"
  connection_draining_timeout_sec = 0
  health_checks                   = [google_compute_health_check.default.id]
  load_balancing_scheme           = "EXTERNAL_MANAGED"
  port_name                       = "http"
  protocol                        = "HTTP"
  session_affinity                = "NONE"
  timeout_sec                     = 30
  backend {
    group           = google_compute_instance_group_manager.default.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# Gelen istekleri Backend servisine yönlendirmek için url map tanımlayalım
resource "google_compute_url_map" "default" {
  name            = "web-map-http"
  default_service = google_compute_backend_service.default.id
}

# Http isteklerini Url map'e yönlendirmek için http proxy oluşturalım
resource "google_compute_target_http_proxy" "default" {
  name    = "http-lb-proxy"
  url_map = google_compute_url_map.default.id
}


# Trafiği doğru http load balancera iletmek için Global forwarding rule tanımlayalım
resource "google_compute_global_forwarding_rule" "default" {
  name                  = "http-content-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80-80"
  target                = google_compute_target_http_proxy.default.id
  ip_address            = google_compute_global_address.default.id
}

resource "google_monitoring_alert_policy" "alert_policy" {
  display_name = "CPU Utilization > 50%"
  documentation {
    content = "The $${metric.display_name} of the $${resource.type} $${resource.label.instance_id} in $${resource.project} has exceeded 50% for over 1 minute."
  }
  combiner     = "OR"
  conditions {
    display_name = "Condition 1"
    condition_threshold {
        comparison = "COMPARISON_GT"
        duration = "60s"
        filter = "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\""
        threshold_value = "0.5"
        trigger {
          count = "1"
        }
    }
  }

  alert_strategy {
    notification_channel_strategy {
        renotify_interval = "1800s"
        notification_channel_names = [google_monitoring_notification_channel.email.name]
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]

  user_labels = {
    severity = "warning"
  }
}

resource "google_monitoring_notification_channel" "email" {
  display_name = "Test Notification Channel"
  type         = "email"
  labels = {
    email_address = "atilla.furkan48@gmail.com"
  }
  force_delete = false
}

# Remote backend bucket oluşturulması

provider "google" {
  project     = "terraform-project-416712"
  region      = "europe-west1"
}
resource "google_storage_bucket" "test-bucket-for-state" {
  name        = "terraform-project-416712"
  location    = "EU" # Replace with EU for Europe region
  uniform_bucket_level_access = false
  versioning {
    enabled = true
  }
}
terraform {
  backend "gcs" {
    bucket  = "terraform-project-416712"
    prefix  = "terraform/state"
  }
}
