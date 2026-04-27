resource "hcloud_load_balancer" "apid" {
  name               = var.project_name
  load_balancer_type = "lb11"
  location           = var.location
}

resource "hcloud_load_balancer_network" "apid" {
  load_balancer_id = hcloud_load_balancer.apid.id
  network_id       = hcloud_network.main.id
  ip               = "10.0.0.2"
}

resource "hcloud_load_balancer_service" "talos_api" {
  load_balancer_id = hcloud_load_balancer.apid.id
  protocol         = "tcp"
  listen_port      = 50000
  destination_port = 50000
}

resource "hcloud_load_balancer_service" "kube_api" {
  load_balancer_id = hcloud_load_balancer.apid.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443
}

resource "hcloud_load_balancer_target" "control_plane" {
  load_balancer_id = hcloud_load_balancer.apid.id
  type             = "label_selector"
  label_selector   = "type=cp"
  use_private_ip   = true
}