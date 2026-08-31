resource "kubernetes_namespace_v1" "eventhub" {
  metadata {
    name = var.namespace

    labels = merge(
      local.common_labels,

      # Pod Security Admission in its strictest mode. Every workload in this
      # module already runs as non-root with all capabilities dropped and a
      # RuntimeDefault seccomp profile, so this costs nothing today and turns a
      # future careless `privileged: true` into a rejected pod rather than a
      # silent privilege escalation.
      var.enforce_pod_security_restricted ? {
        "pod-security.kubernetes.io/enforce" = "restricted"
        "pod-security.kubernetes.io/audit"   = "restricted"
        "pod-security.kubernetes.io/warn"    = "restricted"
      } : {},
    )
  }
}
