variable agent_count {
  default = 2
}

variable dns_prefix {
  default = "aks-k8s-2022"
}

variable cluster_name {
  default = "aks-k8s-2022"
}

variable acr_name {
  default = "acrforaks2022"
}

variable sql_name {
  default = "mssql-2022"
}

variable db_name {
  default = "ProductsDB"
}

variable db_admin_login {
  default = "houssem"
}

variable db_admin_password {
  default = "@Aa123456"
}

variable storage_name {
  default = "mssqlstorageaccount2022"
}

variable key_vault_name {
  default = "keyvaultforaks"
}

variable resource_group_name {
  default = "rg-aks-k8s-2022"
}

variable location {
  default = "westeurope"
}
