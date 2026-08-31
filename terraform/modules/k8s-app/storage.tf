# StorageClass backed by the EBS CSI driver, installed as a managed add-on by
# the eks-addons module.
#
# EKS ships a default `gp2` class. This one is deliberately not marked default,
# because two defaults is an error state — the API server picks one arbitrarily
# and PVCs land on whichever it chose. The PostgreSQL StatefulSet names this
# class explicitly instead, which is the habit worth teaching anyway: a workload
# should say what storage it needs rather than inherit whatever the cluster
# happens to default to.

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name   = var.storage_class_name
    labels = local.common_labels
  }

  storage_provisioner = "ebs.csi.aws.com"

  # Delete tears the EBS volume down with the PVC, which is what a workshop
  # wants. Retain is right for a database you cannot re-seed: the volume then
  # survives the cluster and has to be cleaned up by hand.
  reclaim_policy = "Delete"

  # The critical setting. Immediate binding creates the EBS volume as soon as
  # the PVC appears, in whatever zone the CSI controller happens to pick — and
  # an EBS volume cannot cross availability zones. If the scheduler then places
  # the pod in a different zone it can never attach, and the pod sits Pending
  # forever with a message nobody reads. WaitForFirstConsumer delays volume
  # creation until the pod is scheduled, so the volume lands in the right zone
  # by construction.
  volume_binding_mode = "WaitForFirstConsumer"

  # Lets a PVC grow later with a simple edit. Shrinking remains impossible.
  allow_volume_expansion = true

  parameters = {
    type = "gp3"

    # gp3 includes 3000 IOPS and 125 MB/s at no extra cost regardless of volume
    # size. gp2 tied IOPS to size, which is why small gp2 volumes were so often
    # the hidden cause of a slow database.
    iops       = "3000"
    throughput = "125"

    encrypted = "true"

    "csi.storage.k8s.io/fstype" = "ext4"
  }
}
