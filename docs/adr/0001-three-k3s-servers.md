# 0001: Three K3s servers with embedded etcd

## Constraint

The platform must stay available when one machine is lost, on a small number of machines, without a separate team to operate the control plane.

## Decision

Run three K3s servers. Each one runs the control plane and a member of the embedded etcd cluster. There are no dedicated agents: workloads run on the same three nodes.

K3s ships one replica of its ingress controller and of CoreDNS. `bootstrap/` spreads both across the three nodes, because a platform whose database survives a node failure but whose DNS does not is not highly available.

## Consequence

- With three etcd members the cluster keeps quorum with one node down. It does not survive two.
- Control plane and workloads share machines, so a noisy workload can affect the API server. Acceptable at this size; larger platforms separate them.
- The number of servers must stay odd. Growing means going to five, not four.
