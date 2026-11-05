// Azure resources for running the identity sync on a schedule.
// See docs/azure-design.md for how they fit together.
//
//   Automation Account   runs the PowerShell 7 runbook, with a system-assigned
//                        managed identity for Graph, Exchange, Key Vault and Storage
//   Key Vault            holds the HRIS API token (RBAC mode)
//   Storage account      private containers for the sync state and audit logs
//   Log Analytics        receives the runbook's job logs, for queries and alerts
//
// Graph and Exchange Online permissions for the managed identity are granted in
// Entra ID after deployment (see the design document); they cannot be set here.

@description('Short prefix for resource names, such as idsync. Lower-case letters and digits only, because it is part of the storage account name.')
@minLength(3)
@maxLength(10)
param namePrefix string

@description('Region for all resources.')
param location string = resourceGroup().location

@description('Days to keep logs in Log Analytics.')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 90

// Built-in role definition IDs.
var storageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var keyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'

// Globally unique names, derived from the resource group so redeploying gives the same names.
var suffix = uniqueString(resourceGroup().id)
var storageName = toLower('${namePrefix}st${suffix}')
var keyVaultName = '${namePrefix}-kv-${suffix}'

resource logs 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${namePrefix}-logs'
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: logRetentionDays
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: take(storageName, 24)
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false // only Entra identities with a role can read or write
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true // earlier copies of sync-state.json can be restored
    deleteRetentionPolicy: { enabled: true, days: 14 }
  }
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'state'
  properties: { publicAccess: 'None' }
}

resource auditContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'audit'
  properties: { publicAccess: 'None' }
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: take(keyVaultName, 24)
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
  }
}

resource automation 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: '${namePrefix}-automation'
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    sku: { name: 'Basic' }
    publicNetworkAccess: true
    disableLocalAuth: true // no Automation account keys; runbooks use the managed identity
  }
}

// The managed identity can read and write the state and audit blobs...
resource storageRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, automation.id, storageBlobDataContributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributor)
    principalId: automation.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ...and read secrets from this vault, nothing more.
resource vaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, automation.id, keyVaultSecretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUser)
    principalId: automation.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Runbook job logs and output go to Log Analytics for queries and alerts.
resource automationDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: automation
  name: 'to-log-analytics'
  properties: {
    workspaceId: logs.id
    logs: [
      { category: 'JobLogs', enabled: true }
      { category: 'JobStreams', enabled: true }
    ]
  }
}

@description('Object ID of the managed identity, for granting Graph and Exchange permissions.')
output automationIdentityPrincipalId string = automation.identity.principalId

@description('Storage account holding the state and audit containers.')
output storageAccountName string = storage.name

@description('Key Vault to store the HRIS API token in.')
output keyVaultName string = vault.name
