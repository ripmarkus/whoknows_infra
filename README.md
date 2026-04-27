
> **Work in Progress**

# Talos Infrstructure

This is for devops.

I built a private Kubernetes cluster on Hetzner Cloud. Just raw infrastructure without managed K8s and no public IPs on any of the nodes.


## The Build

This is a production style cluster where none of the Kubernetes nodes are reachable from the internet. All outbound traffic is routed through a NAT VM and the only public entry point is a load balancer, sitting in front of the control plane.

```
Internet → Load Balancer (public IP)
                │
         Private Network (10.0.0.0/16)
         ├── nat-vm   — outbound NAT gateway
         ├── cp1      — control plane
         ├── cp2      — control plane
         ├── cp3      — control plane
         └── worker1  — worker node

```

Every node is running a distro called Talos Linux which is an API driven OS that contains no shell and therefore no SSH either.


## Why?

The goal was to build a cluster that behaves more like real infrastructure than a throwaway homelab. I did not want publicly reachable nodes or a managed control plane hiding the operational details. I wanted to handle the network design myself and understand how the pieces fit together.

By keeping all nodes on a private network and forcing ingress and egress through controlled points, the cluster has a much smaller attack surface and a cleaner security model. It is also a practical way to explore patterns that show up in production environments, especially around isolation, routing, and controlled access.

Running this on Hetzner keeps the cost reasonable while still giving me full control over the infrastructure. That makes it a good platform for learning Kubernetes in a way that is hands-on and close to real operational work.
