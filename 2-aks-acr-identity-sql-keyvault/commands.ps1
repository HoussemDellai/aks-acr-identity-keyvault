
more https://blog.jcorioland.io/archives/2019/09/04/terraform-microsoft-azure-introduction.html
rm .\terraform.tfstate
rm .\terraform.tfstate.backup
# terraform destroy -auto-approve 
# sleep 420
terraform graph | dot -Tsvg > graph.svg
$TF_LOG="DEBUG"
terraform plan
terraform apply -auto-approve

echo "Setting up the variables..."
$subscriptionId = (az account show | ConvertFrom-Json).id
$tenantId = (az account show | ConvertFrom-Json).tenantId
$resourceGroupName = "rg-aks-k8s-2022"
$aksName = "aks-k8s-2022"
$keyVaultName = "keyvaultforaks"
$secret1Name = "DatabaseLogin"
$secret2Name = "DatabasePassword"
$secret1Alias = "DATABASE_LOGIN"
$secret2Alias = "DATABASE_PASSWORD" 
$identityName = "identity-aks-kv"
$identitySelector = "azure-kv"
$secretProviderClassName = "secret-provider-kv"

# retrieve existing AKS
$aks = (az aks show -n $aksName -g $resourceGroupName | ConvertFrom-Json)

# echo "Connecting/athenticating to AKS..."
az aks get-credentials -n $aksName -g $resourceGroupName --overwrite-existing

echo "Retrieving Key Vault..."
$keyVault = az keyvault show -n $keyVaultName | ConvertFrom-Json # retrieve existing KV

echo "Using the Azure Key Vault Provider..."
$secretProviderKV = @"
apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
kind: SecretProviderClass
metadata:
  name: $($secretProviderClassName)
spec:
  provider: azure
  parameters:
    usePodIdentity: "true"
    useVMManagedIdentity: "false"
    userAssignedIdentityID: ""
    keyvaultName: $keyVaultName
    cloudName: AzurePublicCloud
    objects:  |
      array:
        - |
          objectName: $secret1Name
          objectAlias: $secret1Alias
          objectType: secret
          objectVersion: ""
        - |
          objectName: $secret2Name
          objectAlias: $secret2Alias
          objectType: secret
          objectVersion: ""
    resourceGroup: $resourceGroupName
    subscriptionId: $subscriptionId
    tenantId: $tenantId
"@
$secretProviderKV | kubectl create -f -

# If using AKS with Managed Identity, retrieve the existing Identity
echo "Retrieving the existing Azure Identity..."
$existingIdentity = az resource list -g $aks.nodeResourceGroup --query "[?contains(type, 'Microsoft.ManagedIdentity/userAssignedIdentities')]"  | ConvertFrom-Json
$identity = az identity show -n $existingIdentity.name -g $existingIdentity.resourceGroup | ConvertFrom-Json

echo "Adding AzureIdentity and AzureIdentityBinding..."
$aadPodIdentityAndBinding = @"
apiVersion: aadpodidentity.k8s.io/v1
kind: AzureIdentity
metadata:
  name: $($identityName)
spec:
  type: 0
  resourceID: $($identity.id)
  clientID: $($identity.clientId)
---
apiVersion: aadpodidentity.k8s.io/v1
kind: AzureIdentityBinding
metadata:
  name: $($identityName)-binding
spec:
  azureIdentity: $($identityName)
  selector: $($identitySelector)
"@
$aadPodIdentityAndBinding | kubectl apply -f -

echo "Deploying a Nginx Pod for testing..."
$nginxPod = @"
kind: Pod
apiVersion: v1
metadata:
  name: nginx-secrets-store
  labels:
    aadpodidbinding: $($identitySelector)
spec:
  containers:
    - name: nginx
      image: nginx
      volumeMounts:
      - name: secrets-store-inline
        mountPath: "/mnt/secrets-store"
        readOnly: true
  volumes:
    - name: secrets-store-inline
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: $($secretProviderClassName)
"@
$nginxPod | kubectl apply -f -

sleep 10
kubectl get pods

echo "Validating the pod has access to the secrets from Key Vault..."
kubectl exec -it nginx-secrets-store ls /mnt/secrets-store/
kubectl exec -it nginx-secrets-store cat /mnt/secrets-store/DATABASE_LOGIN
kubectl exec -it nginx-secrets-store cat /mnt/secrets-store/$secret1Alias
kubectl exec -it nginx-secrets-store cat /mnt/secrets-store/DATABASE_PASSWORD
kubectl exec -it nginx-secrets-store cat /mnt/secrets-store/$secret2Alias

# Testing ACR and AKS authN
# az acr build -t productsstore:0.1 -r $acrName .\ProductsStoreOnKubernetes\MvcApp\
# kubectl run --image=$acrName.azurecr.io/productsstore:0.1 prodstore --generator=run-pod/v1

# clean up resources 
# az keyvault purge -n $keyVaultName
# az group delete --no-wait --yes -n $resourceGroupName
# az group delete --no-wait --yes -n $aks.nodeResourceGroup