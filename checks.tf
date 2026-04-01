# Cross-variable rules (variable validation may only reference the same variable).
check "failover_ad_distinct_from_benchmark" {
  assert {
    condition = !var.enable_failover_node || (
      length(trimspace(var.failover_ad)) > 0 && var.failover_ad != var.benchmark_ad
    )
    error_message = "When enable_failover_node is true, failover_ad must be set and must not match benchmark_ad (choose a different AD)."
  }
}
