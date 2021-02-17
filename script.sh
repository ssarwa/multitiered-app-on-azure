# Initialize variables

# Add variables (sample values below change as required)
RG='CNCF-Azure-RG'
CLUSTER_NAME='myaksCluster'
LOCATION='westus'
AppGtwy='AKSAppGtwy'
ACR='myPrivateReg'
domainName='sarwascloud.com'
MYSQL='expensedbserver'
adminUser=''
mysqlPwd=''
KeyVault='expensesvault'
identityName='exppoidentity' # Must be lower case
storageAcc='expensesqueue'
queueName='contosoexpenses'
SUBID='12bb4e89-4f7a-41e0-a38f-b22f079248b4'

#### Login to Azure

az login
az account set -s $SUBID

#### Register to AKS preview features
# Follow https://docs.microsoft.com/en-us/azure/aks/use-azure-ad-pod-identity
az feature register --name EnablePodIdentityPreview --namespace Microsoft.ContainerService
az provider register -n Microsoft.ContainerService
az extension add --name aks-preview
az extension update --name aks-preview

#### Create Resource Group
az group create --name $RG --location $LOCATION

#### Create ACR
az acr create --resource-group $RG --name $ACR --sku Standard

#### Get Object ID of the AAD Group (create AAD Group and add the members, in this case: fta-cncf-azure)
objectId=$(az ad group list --filter "displayname eq 'fta-cncf-azure'" --query '[].objectId' -o tsv)

#### Create an AKS-managed Azure AD cluster with AGIC addon and AAD Pod Identity
az aks create \
    -n $CLUSTER_NAME \
    -g $RG \
    --network-plugin azure \
    --enable-managed-identity \
    -a ingress-appgw --appgw-name $AppGtwy \
    --appgw-subnet-cidr "10.2.0.0/16" \
    --enable-aad \
    --enable-pod-identity \
    --aad-admin-group-object-ids $objectId \
    --generate-ssh-keys \
    --attach-acr $ACR

#### Add Public IP to custom domain
# Get Node Resource Group
nodeRG=$(az aks show --resource-group $RG --name $CLUSTER_NAME --query nodeResourceGroup -o tsv)

# Get Public IP created by App Gtwy in AKS created cluster
appIP=$(az network public-ip show -g $nodeRG -n $AppGtwy-appgwpip --query ipAddress -o tsv)

# Create DNS zone 
az network dns zone create -g $RG -n $domainName

# Once created, add Nameservers in the domain provider (eg go daddy, may take sometime to update the name servers)

az network dns record-set a add-record --resource-group $RG --zone-name $domainName --record-set-name "aks" --ipv4-address $appIP

### Connect to the Cluster

#### Merge Kubeconfig
az aks get-credentials --resource-group $RG --name $CLUSTER_NAME --admin

#### Install Cert Manager
# Install the CustomResourceDefinition resources separately
# Note: --validate=false is required per https://github.com/jetstack/cert-manager/issues/2208#issuecomment-541311021
kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.13/deploy/manifests/00-crds.yaml --validate=false
kubectl create namespace cert-manager
kubectl label namespace cert-manager cert-manager.io/disable-validation=true
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager --namespace cert-manager --version v0.13.0 jetstack/cert-manager
kubectl apply -f yml/clusterissuer.yaml

# Test a sample application. The below command will deploy a Pod, Service and Ingress resource. Application Gateway will be configured with the associated rules.
kubectl apply -f yml/Test-App-Ingress.yaml

# Clean up after successfully verifying AGIC
kubectl delete -f yml/Test-App-Ingress.yaml

#### Install OSM Service Mesh (To-do, skip this section for now)
# Install OSM on local using https://github.com/openservicemesh/osm#install-osm
# Install OSM on Kubernetes
osm install --mesh-name exp-osm

# Enable OSM on the namespace. Enables sidecar injection
osm namespace add default

#### Install KEDA runtime
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
kubectl create namespace keda
helm install keda kedacore/keda --namespace keda

#### Install CSI Provider for Azure Keyvault
helm repo add csi-secrets-store-provider-azure https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/charts
helm repo update
kubectl create namespace csi
helm install csi csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --namespace csi

#### Assign managed identity
clientId=$(az aks show -n $CLUSTER_NAME -g $RG --query identityProfile.kubeletidentity.clientId -o tsv)
scope=$(az group show -g $nodeRG --query id -o tsv)
az role assignment create --role "Managed Identity Operator" --assignee $clientId --scope $scope

#### Create Azure Keyvault for saving secrets and assign identity
az keyvault create --location $LOCATION --name $KeyVault --resource-group $RG
kvscope=$(az keyvault show -g $RG -n $KeyVault --query id -o tsv)
az identity create -g $RG -n $identityName
idClientid=$(az identity show -n $identityName -g $RG --query clientId -o tsv)
idPincipalid=$(az identity show -n $identityName -g $RG --query principalId -o tsv)
identityId=$(az identity show -n $identityName -g $RG --query id -o tsv)
az role assignment create --role "Reader" --assignee $idPincipalid --scope $kvscope
az keyvault set-policy -n $KeyVault --secret-permissions get --spn $idClientid
az aks pod-identity add --resource-group $RG --cluster-name $CLUSTER_NAME --namespace default --name $identityName --identity-resource-id $identityId

#### Create MySQL managed service (basic sku) and add Kubernetes Load Balancer's public ip in it firewall rules
aksPublicIpName=$(az network lb show -n kubernetes -g $nodeRG --query "frontendIpConfigurations[0].name" -o tsv)
aksPublicIpAddress=$(az network public-ip show -n $aksPublicIpName -g $nodeRG --query ipAddress -o tsv)
az mysql server create --resource-group $RG --name $MYSQL --location $LOCATION --admin-user $adminUser --admin-password $mysqlPwd --sku-name B_Gen5_2
az mysql server firewall-rule create --name allowip --resource-group $RG --server-name $MYSQL --start-ip-address $aksPublicIpAddress --end-ip-address $aksPublicIpAddress
az mysql server firewall-rule create --name devbox --resource-group $RG --server-name $MYSQL --start-ip-address <Dev station ip> --end-ip-address <Dev station ip>

#### Login to MySQL (you may need to add you ip to firewall rules as well)
mysql -h $MYSQL.mysql.database.azure.com -u $adminUser@$MYSQL -p
show databases;

CREATE DATABASE conexpweb;

CREATE DATABASE conexpapi;
USE conexpapi;

CREATE TABLE CostCenters(
   CostCenterId int(11)  NOT NULL,
   SubmitterEmail text NOT NULL,
   ApproverEmail text NOT NULL,
   CostCenterName text NOT NULL,
   PRIMARY KEY ( CostCenterId )
);

# Insert example records
INSERT INTO CostCenters (CostCenterId, SubmitterEmail,ApproverEmail,CostCenterName)  values (1, 'ssarwa@microsoft.com', 'ssarwa@microsoft.com','123E42');
INSERT INTO CostCenters (CostCenterId, SubmitterEmail,ApproverEmail,CostCenterName)  values (2, 'ssarwa@microsoft.com', 'ssarwa@microsoft.com','456C14');
INSERT INTO CostCenters (CostCenterId, SubmitterEmail,ApproverEmail,CostCenterName)  values (3, 'ssarwa@microsoft.com', 'ssarwa@microsoft.com','456C14');

quit

#### Create Storage queue
az storage account create -n $storageAcc -g $RG -l $LOCATION --sku Standard_LRS
az storage queue create -n $queueName --account-name $storageAcc

#### Add corresponding secrets to the create KeyVault

#1. MySQL Connection strings (choose ADO.NET) - both for API and Web
#   1. mysqlconnapi
#   2. mysqlconnweb
#2. Storage Connection strings
#   1. storageconn
#3. Sendgrid Key
#   1. sendgridapi

az keyvault secret set --vault-name $KeyVault --name mysqlconnapi --value '<replace>Connection strings for MySQL API connection</replace>'
az keyvault secret set --vault-name $KeyVault --name mysqlconnweb --value '<replace>Connection strings for MySQL Web connection</replace>'
az keyvault secret set --vault-name $KeyVault --name storageconn --value '<replace>Connection strings for Storage account</replace>'
az keyvault secret set --vault-name $KeyVault --name sendgridapi --value '<replace>Sendgrid Key</replace>'
az keyvault secret set --vault-name $KeyVault --name funcruntime --value 'dotnet'

#### Application Deployment
# Clone the repo
git clone https://github.com/ssarwa/cncf-azure.git
registryHost=$(az acr show -n $ACR --query loginServer -o tsv)
az acr login -n $ACR
cd source/Contoso.Expenses.API
docker build -t $registryHost/conexp/api:latest .
docker push $registryHost/conexp/api:latest
cd ..
docker build -t $registryHost/conexp/web:latest -f Contoso.Expenses.Web/Dockerfile .
docker push $registryHost/conexp/web:latest
docker build -t $registryHost/conexp/emaildispatcher:latest -f Contoso.Expenses.KedaFunctions/Dockerfile .
docker push $registryHost/conexp/emaildispatcher:latest
cd ..

# Update yamls files and change identity name, keyvault name and image used
# Create CSI Provider Class
kubectl apply -f yml/csi-sync.yaml

# Create API
kubectl apply -f yml/backend.yaml

# Create frontend
kubectl apply -f yml/frontend.yaml

# Create KEDA function
kubectl apply -f yml/function.yaml

#### Prepare Github Actions
# Get Resource Group ID
groupId=$(az group show --name $RG --query id -o tsv)

# Create Service Principal and save the output
az ad sp create-for-rbac --scope $groupId --role Contributor --sdk-auth

# Get ACR ID
registryId=$(az acr show --name $ACR --query id --output tsv)

# Assign ACR Push role
az role assignment create \
  --assignee <ClientId> \
  --scope $registryId \
  --role AcrPush

# Now you are ready to trigger the build and release from Github Actions using the provided Actions file.