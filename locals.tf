locals {
  # Where the durable EBS volume mounts; all heavy trees (work repos, tool installs,
  # caches, logs) live under it. orb reads this same path from its config.
  data_mount = "/mnt/data"
}
