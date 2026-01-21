# Variables for Workload Identity test configuration

variable "test_dynamic_credentials" {
  description = "Enable testing of dynamic database credentials from Vault"
  type        = bool
  default     = false
}

variable "test_pki" {
  description = "Enable testing of PKI certificate issuance from Vault"
  type        = bool
  default     = false
}

variable "secret_path" {
  description = "Path to the secret in Vault KV v2"
  type        = string
  default     = "test/workload-identity"
}
