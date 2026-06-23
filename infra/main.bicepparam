using './main.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', 'eastus2')
param prefix = readEnvironmentVariable('PREFIX', 'fdr')
param env = readEnvironmentVariable('ENV', 'dev')
param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'dev')
param myIpAddress = readEnvironmentVariable('MY_IP', '')
