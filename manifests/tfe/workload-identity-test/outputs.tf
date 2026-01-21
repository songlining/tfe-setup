# Outputs for Workload Identity test verification

output "vault_connection_test" {
  description = "Result of Vault connection test via Workload Identity"
  value = {
    authenticated = length(data.vault_kv_secret_v2.test_secret.data) > 0 || can(data.vault_kv_secret_v2.test_secret.data)
    secret_path   = var.secret_path
    data          = try(data.vault_kv_secret_v2.test_secret.data, {})
  }
}

output "dynamic_credentials_test" {
  description = "Result of dynamic credentials test (if enabled)"
  value = var.test_dynamic_credentials ? {
    generated = try(length(vault_database_credentials.test_db_creds) > 0, false)
    creds     = try(vault_database_credentials.test_db_creds[0].*, {})
  } : {
    generated = false
    message   = "Dynamic credentials test not enabled - set test_dynamic_credentials=true"
  }
}

output "pki_test" {
  description = "Result of PKI certificate test (if enabled)"
  value = var.test_pki ? {
    generated = try(length(data.vault_pki_secret_backend_cert.test_cert) > 0, false)
    cert      = try(data.vault_pki_secret_backend_cert.test_cert[0].certificate, "")
  } : {
    generated = false
    message   = "PKI test not enabled - set test_pki=true"
  }
}
