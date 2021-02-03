# Multi-tiered expense application

## Overview

This article demonstrates a multi-tiered application to Azure Kubernetes Service deployment with Managed Azure Services and workflow automation

## Architecture

![Architecture](Architecture.jpg)

## Setup

We will create and setup the infrastructure including the following services:

1. Azure Container Registry for storing images
2. AAD Enabled, Managed AKS Cluster with the below addons and components
   1. Application Gateway Ingress Controller Addon
   2. Monitoring Addon
   3. LetsEncrypt for Certificate authority
   4. KEDA runtime for Azure Functions on Kubernetes clusters
   5. Open Service Mesh
3. Github repository with Github Actions
4. Azure Database for MySQL Service
5. DNS Zone for custom domain
6. SendGrid Account for email service

### Cluster Creation

#### Initialize variables

```bash
RG='CNCF-Azure-RG'
CLUSTER_NAME='cncfazcluster'
LOCATION='westus'
AppGtwy='CNCFAppGtwy'
ACR='cncfazure'
domainName='sarwascloud.com'
MYSQL='expensedbserver'
adminUser='expenseadmin'
mysqlPwd='Azure1234!@#$'
```

#### Login to Azure

```bash
az login
```

#### Create Resource Group

```bash
az group create --name $RG --location $LOCATION
```

#### Create ACR

```bash
az acr create --resource-group $RG --name $ACR --sku Standard
```

#### Get Object ID of the AAD Group (create AAD Group and add the members, in this case: fta-cncf-azure)

```bash
objectId=$(az ad group list --filter "displayname eq 'fta-cncf-azure'" --query '[].objectId' -o tsv)
```

#### Create an AKS-managed Azure AD cluster with AGIC addon

```bash
az aks create \
    -n $CLUSTER_NAME \
    -g $RG \
    --network-plugin azure \
    --enable-managed-identity \
    -a ingress-appgw --appgw-name $AppGtwy \
    --appgw-subnet-prefix "10.2.0.0/16" \
    --enable-aad \
    --aad-admin-group-object-ids $objectId \
    --generate-ssh-keys \
    --attach-acr $ACR
```

#### Add Public IP to custom domain

```bash
# Get Node Resource Group
nodeRG=$(az aks show --resource-group $RG --name $CLUSTER_NAME --query nodeResourceGroup -o tsv)

# Get Public IP created by App Gtwy in AKS created cluster
appIP=$(az network public-ip show -g $nodeRG -n $AppGtwy-appgwpip --query ipAddress -o tsv)

# Create DNS zone 
az network dns zone create -g $RG -n $domainName

# Once created, add Nameservers in the domain provider (eg go daddy, may take sometime to update the name servers)

az network dns record-set a add-record --resource-group $RG --zone-name $domainName --record-set-name "aks" --ipv4-address $appIP
```

### Connect to the Cluster

#### Merge Kubeconfig

```bash
az aks get-credentials --resource-group $RG --name $CLUSTER_NAME --admin
```

#### Install Cert Manager

```bash
# Install the CustomResourceDefinition resources separately
# Note: --validate=false is required per https://github.com/jetstack/cert-manager/issues/2208#issuecomment-541311021
kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.13/deploy/manifests/00-crds.yaml --validate=false

# Create the namespace for cert-manager
kubectl create namespace cert-manager

# Label the cert-manager namespace to disable resource validation
kubectl label namespace cert-manager cert-manager.io/disable-validation=true

# Add the Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io

# Update your local Helm chart repository cache
helm repo update

# Install v0.11 of cert-manager Helm chart
helm install cert-manager --namespace cert-manager --version v0.13.0 jetstack/cert-manager

# Install Cluster Issuer (change email address)
kubectl apply -f yml/clusterissuer.yaml

# Test a sample application. The below command will deploy a Pod, Service and Ingress resource. Application Gateway will be configured with the associated rules.
kubectl apply -f yml/Test-App-Ingress.yaml
```

#### Create MySQL managed service (basic sku)

```bash
az mysql server create --resource-group $RG --name MYSQL --location $LOCATION --admin-user $adminUser --admin-password $mysqlPwd --sku-name B_Gen5_2
```

#### Install KEDA runtime

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
kubectl create namespace keda
helm install keda kedacore/keda --namespace keda
```

