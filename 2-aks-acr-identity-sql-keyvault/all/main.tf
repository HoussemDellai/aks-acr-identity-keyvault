# src: https://www.chriswoolum.dev/aks-with-managed-identity-and-terraform

provider "azurerm" {
  version = ">=2.0"
  # The "feature" block is required for AzureRM provider 2.x.
  features {}
}

provider "helm" {
  version = ">= 1.2.1"
  kubernetes {
    # host     = azurerm_kubernetes_cluster.aks.kube_config.0.host

    # client_key             = "base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)"
    # client_certificate     = "base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)"
    # cluster_ca_certificate = "base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)"
  }
}

provider "kubernetes" {
  version = ">= 1.11"
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

data "azurerm_client_config" "current" {
}

# data "azurerm_subscription" "current" {
# }

#################################################################################
#   AKS
#################################################################################

resource "azurerm_kubernetes_cluster" "aks" {
  name                = var.cluster_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = var.dns_prefix
  kubernetes_version  = "1.17.3" # "1.18.2"

  default_node_pool {
    name       = "default"
    node_count = var.agent_count
    vm_size    = "Standard_DS1_v2"
  }

  identity {
    type = "SystemAssigned"
  }
  # service_principal {
  #   client_id     = var.client_id
  #   client_secret = var.client_secret
  # }

  role_based_access_control {
    enabled = true
  }

  network_profile {
    network_plugin = "kubenet"
    network_policy = "calico"
  }

  tags = {
    Environment = "Development"
  }
  
  # runs only after aks creation
  provisioner "local-exec" {
    command = "az aks get-credentials -g rg-aks-k8s-2022 -n aks-k8s-2022 --overwrite-existing"
    // command = "az aks get-credentials -g azurerm_kubernetes_cluster.aks.resource_group_name -n azurerm_kubernetes_cluster.aks.name --overwrite-existing"
  }
}

data "azurerm_user_assigned_identity" "identity" {
  name                = "${azurerm_kubernetes_cluster.aks.name}-agentpool"
  resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group
}

#################################################################################
#   ACR
#################################################################################

resource "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Standard"
  admin_enabled       = false
}

resource "azurerm_role_assignment" "role_acrpull" {
  # name                             = "acrpull"
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = data.azurerm_user_assigned_identity.identity.principal_id
  skip_service_principal_aad_check = true
}

#################################################################################
#   Key Vault
#################################################################################

resource "azurerm_key_vault" "keyvault" {
  name                        = var.key_vault_name
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  enabled_for_disk_encryption = false
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_enabled         = false
  purge_protection_enabled    = false

  sku_name = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions = [
      "get",
    ]

    secret_permissions = [
      "set",
      "get",
      "list",
      "delete",
    ]

    storage_permissions = [
      "get",
    ]
  }

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = {
    environment = "Testing"
  }
}

resource "azurerm_key_vault_secret" "secret-password" {
  name         = "DatabasePassword"
  value        = var.db_admin_password
  key_vault_id = azurerm_key_vault.keyvault.id
}

resource "azurerm_key_vault_secret" "secret-login" {
  name         = "DatabaseLogin"
  value        = var.db_admin_login
  key_vault_id = azurerm_key_vault.keyvault.id
}

# az role assignment create 
#    --role "Reader" 
#    --assignee $identity.principalId 
#    --scope $keyVault.id

resource "azurerm_role_assignment" "role_keyvault_reader" {
  # name                             = "keyvaultreader"
  role_definition_name             = "Reader"
  principal_id                     = data.azurerm_user_assigned_identity.identity.principal_id
  scope                            = azurerm_key_vault.keyvault.id
  skip_service_principal_aad_check = true
}

# az role assignment create 
#    --role "Managed Identity Operator" 
#    --assignee $aks.identityProfile.kubeletidentity.clientId 
#    --scope /subscriptions/$subscriptionId/resourcegroups/$($aks.nodeResourceGroup)

resource "azurerm_role_assignment" "role_rg_operator" {
  role_definition_name             = "Managed Identity Operator"
  principal_id                     = data.azurerm_user_assigned_identity.identity.principal_id
  scope                            = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourcegroups/${azurerm_kubernetes_cluster.aks.node_resource_group}"
  skip_service_principal_aad_check = true
}

# az role assignment create 
#    --role "Virtual Machine Contributor" 
#    --assignee $aks.identityProfile.kubeletidentity.clientId 
#    --scope /subscriptions/$subscriptionId/resourcegroups/$($aks.nodeResourceGroup)

resource "azurerm_role_assignment" "role_vm_contributor" {
  role_definition_name             = "Virtual Machine Contributor"
  principal_id                     = data.azurerm_user_assigned_identity.identity.principal_id
  scope                            = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourcegroups/${azurerm_kubernetes_cluster.aks.node_resource_group}"
  skip_service_principal_aad_check = true
}

# az keyvault set-policy -n $keyVaultName --secret-permissions get --spn $identity.clientId

resource "azurerm_key_vault_access_policy" "keyvault_policy" {
  key_vault_id = azurerm_key_vault.keyvault.id

  tenant_id = data.azurerm_client_config.current.tenant_id
  object_id = data.azurerm_user_assigned_identity.identity.principal_id

  secret_permissions = [
    "get",
  ]

  depends_on = [
    azurerm_key_vault.keyvault
  ]
}

#################################################################################
#   Azure SQL
#################################################################################

// resource "azurerm_sql_server" "sql" {
//   name                         = var.sql_name
//   resource_group_name          = azurerm_resource_group.rg.name
//   location                     = azurerm_resource_group.rg.location
//   version                      = "12.0"
//   administrator_login          = var.db_admin_login
//   administrator_login_password = var.db_admin_password
// }

// resource "azurerm_storage_account" "storage" {
//   name                     = var.storage_name
//   resource_group_name      = azurerm_resource_group.rg.name
//   location                 = azurerm_resource_group.rg.location
//   account_tier             = "Standard"
//   account_replication_type = "LRS"
// }

// resource "azurerm_sql_database" "db" {
//   name                = var.db_name
//   resource_group_name = azurerm_resource_group.rg.name
//   location            = azurerm_resource_group.rg.location
//   server_name         = azurerm_sql_server.sql.name
//   create_mode         = "Default"
//   edition             = "Basic"

//   tags = {
//     environment = "production"
//   }
// }

// resource "azurerm_sql_firewall_rule" "rule" {
//   name                = "AllowAzureServicesAndResources"
//   resource_group_name = azurerm_resource_group.rg.name
//   server_name         = azurerm_sql_server.sql.name
//   # The Azure feature Allow access to Azure services can be enabled 
//   # by setting start_ip_address and end_ip_address to 0.0.0.0
//   start_ip_address = "0.0.0.0"
//   end_ip_address   = "0.0.0.0"
// }

#################################################################################
#   HELM
#################################################################################

resource "kubernetes_namespace" "csi_driver_namespace" {
  metadata {
    name = "csi-driver"
  }

  depends_on = [
    azurerm_kubernetes_cluster.aks
  ]
}

resource "helm_release" "csi_azure_release" {
  name       = "csi-keyvault"
  repository = "https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts"
  chart      = "csi-secrets-store-provider-azure"
  # version    = "0.0.6"
  namespace  = kubernetes_namespace.csi_driver_namespace.metadata[0].name

  # values = [
  #   "${file("values.yaml")}"
  # ] 

  depends_on = [
    azurerm_kubernetes_cluster.aks
  ]
}

resource "helm_release" "pod_identity_release" {
  name       = "pod-identity"
  repository = "https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts"
  chart      = "aad-pod-identity"
  namespace  = "default"

  depends_on = [
    azurerm_kubernetes_cluster.aks
  ]
}