param (    
    #[string] $serviceConnectionJsonPath = "../data/service_connections.json",
    [int]    $jsonDepth = 100,
    [bool]   $isProductionRun = $false,
    [bool]   $refreshServiceConnectionsIfTheyExist = $false,
    [string] $apiVersion = "6.0-preview.4",
    [bool]   $skipPauseAfterError = $false,
    [bool]   $skipPauseAfterWarning = $false,
    [bool]   $revertAll = $false
)

$totalNumberOfArmServiceConnections = 0
$numberOfArmServiceConnectionsWithWorkloadIdentityFederationAutomatic = 0
$numberOfArmServiceConnectionsWithWorkloadIdentityFederationManual = 0
$numberOfArmServiceConnectionsWithServicePrincipalAutomatic = 0
$numberOfArmServiceConnectionsWithServicePrincipalManual = 0
$numberOfArmServiceConnectionsWithManagedIdentity = 0
$numberOfArmServiceConnectionsWithPublishProfile = 0

$numberOfFederatedCredentialsCreatedManually = 0
$numberOfSharedArmServiceConnections = 0

$totalNumberOfArmServiceConnectionWithServicePrincipalConvertedToWorkloadIdentityFederation = 0
$totalNumberOfArmServiceConnectionWithServicePrincipalThatDidNotConvertToWorkloadIdentityFederation = 0

$totalNumberOfArmServiceConnectionWithWorkloadIdentityFederationRevertedBackToServicePrincipal = 0
$totalNumberOfArmServiceConnectionWithWorkloadIdentityFederationThatDidNotRevertBackToServicePrincipal = 0

$hashTableAdoResources = @{}

function Get-AzureDevOpsOrganizationOverview {  

    [CmdletBinding()]
    param (
        [string] $tenantId
    )

    #Disconnect-AzAccount
    Clear-AzContext -Force

    $login = Connect-AzAccount -Tenant $tenantId

    if (!$login) {
        Write-Error 'Error logging in and validating your credentials.'
        return;
    }

    $adoResourceId = "499b84ac-1321-427f-aa17-267ca6975798" # Azure DevOps app ID

    $msalToken = (Get-AzAccessToken -ResourceUrl $adoResourceId).Token 

    if (!$tenantId) {
        $tenantId = $msalToken.tenantId
        Write-Verbose "Set TenantId to $tenantId (retrieved from MSAL token)"
    }

    # URL retrieved thanks to developer mod at page https://dev.azure.com/<organizationName>/_settings/organizationAad
    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"    
    $headers.Add("Authorization", "Bearer ${msalToken}")

    $response = Invoke-WebRequest -Uri "https://aexprodweu1.vsaex.visualstudio.com/_apis/EnterpriseCatalog/Organizations?tenantId=$tenantId" `
        -Method get -ContentType "application/json" `
        -Headers $headers | Select-Object -ExpandProperty content | ConvertFrom-Csv

    $responseJson = $response | ConvertTo-Json -Depth $jsonDepth

    $outputFile = "organizations_${tenantId}.json"
    Set-Content -Value $responseJson -Path $outputFile
}

# Get-OrganizationId
# This function is used to get the organization id for an organization name
# Parameters
#   organizationName: the name of the organization
#   tenantId: the id of the tenant that this organization belongs to
# Returns
#   the id of the organization
#   "" if the organization was not found

function Get-OrganizationId {
    param (
        [string] $organizationName,
        [string] $tenantId
    )
    $outputFile = "organizations_${tenantId}.json"
    $exists = Test-Path -Path $outputFile -PathType Leaf
    if (-not $exists) {
        Write-Host "File $outputFile not found..."
        Get-AzureDevOpsOrganizationOverview -tenantId $tenantId
    }
    $allOrganizationsJson = Get-Content -Path $outputFile 
    $allOrganizations = $allOrganizationsJson | ConvertFrom-Json

    $organizationFound = $allOrganizations | Where-Object { $_."Organization Name" -eq $organizationName }
    
    if ($organizationFound) {
        Write-Host $organizationFound
        $organizationId = $organizationFound[0]."Organization Id"
        Write-Host "Organization $organizationName has id ${organizationId}"
        return $organizationId
    }
    else {
        Write-Warning "did not find org $organizationName in tenant $tenantId"
        return ""
    }
}

function Get-Projects {
    param (
        [string] $organizationUrl
    )
    # get projects - Implement continuation token

    $token = $null
    $allProjects = @()  

    do {
        if ($null -eq $token) {
            $projectsRawJson = az devops project list --organization $organizationUrl
        }
        else {
            $projectsRawJson = az devops project list --organization $organizationUrl --continuation-token $Token
        }

        $projectsRaw = $projectsRawJson | ConvertFrom-Json -Depth $jsonDepth
        $projects = $projectsRaw.value
        $token = $projectsRaw.ContinuationToken
        
        $allProjects += $projects
    }
    while ($null -ne $token)

    return $projects
} 

function Get-ServiceConnections {
    param (
        [Parameter(mandatory = $true)]
        [string] $tenantId,
        [Parameter(mandatory = $true)]
        [string] $serviceConnectionJsonPath,
        [string] $organizationsOutputFile = "organizations_${tenantId}.json",
        [bool]   $refreshServiceConnectionsIfTheyExist = $false,
        [string] $filterType = "AzureRM"
    )
    $exported = $false
    
    $organizationsOutputFileExists = Test-Path -Path $organizationsOutputFile -PathType Leaf
    if (-not $organizationsOutputFileExists) {
        Write-Host "File $organizationsOutputFile not found..."
        Get-AzureDevOpsOrganizationOverview -tenantId $tenantId
    }
    $allOrganizationsJson = Get-Content -Path $organizationsOutputFile 
    $allOrganizations = $allOrganizationsJson | ConvertFrom-Json

    $serviceConnectionsOutputFileExists = Test-Path -Path $serviceConnectionJsonPath -PathType Leaf    

    $skipFetchingServiceConnections = $serviceConnectionsOutputFileExists -and (-not $refreshServiceConnectionsIfTheyExist)

    Write-Host "serviceConnectionsOutputFileExists: $serviceConnectionsOutputFileExists"
    Write-Host "refreshServiceConnectionsIfTheyExist: $refreshServiceConnectionsIfTheyExist"
    Write-Host "skipFetchingServiceConnections: $skipFetchingServiceConnections"

    if ($skipFetchingServiceConnections) {
        Write-Host "File $serviceConnectionJsonPath already exists and refreshServiceConnectionsIfTheyExist is set to false. Skipping..."
        $exported = $true
        return $exported
    }

    # get all service connections
    $allServiceConnections = @()

    foreach ($organization in $allOrganizations ) {
        $organizationName = $organization."Organization Name"
        $organizationId = $organization."Organization Id"
        $organizationUrl = $organization."Url"
        
        $projects = Get-Projects -organizationUrl $organizationUrl

        foreach ($project in $projects) {
            $projectName = $project.name
            Write-Host "Org: ${organizationName} Proj: ${projectName}"
            # get service connections
            $serviceEndpointsJson = az devops service-endpoint list --organization $organizationUrl --project $projectName
            $serviceEndpoints = $serviceEndpointsJson | ConvertFrom-Json -Depth 100            
            Write-Host "`tOrganization $organizationName has project $projectName with $($serviceEndpoints.Length) service endpoints."
            $armServiceEndpoints = $serviceEndpoints | Where-Object { $_.type -eq $filterType } #should be case insensitive
            Write-Host "`tOrganization $organizationName has project $projectName with $($armServiceEndpoints.Length) ARM service endpoints."
            $allServiceConnections += $armServiceEndpoints
            foreach ($armServiceEndpoint in $armServiceEndpoints) {
                $serviceConnectionName = $armServiceEndpoint.name
                $endpointId = $armServiceEndpoint.id
                Write-Host "`t`tOrganization $organizationName has project $projectName with ARM service endpoint $serviceConnectionName with id $endpointId."

                $projSvcEndpoint = @{
                    "organizationName" = $organizationName
                    "organizationId"   = $organizationId
                    "projectName"      = $projectName
                    "serviceEndpoint"  = $armServiceEndpoint
                }
                if ($hashTableAdoResources.ContainsKey("$endpointId")) {
                    Write-Warning "endpointId $endpointId already exists in hash table"
                    $isShared = $($armServiceEndpoint.isShared)
                    if ($isShared) {
                        Write-Warning "connection is shared as expected"
                    }
                    else {
                        throw "endpointId $endpointId already exists in hash table but is not shared"
                    }
                }
                else {
                    Write-Host "adding endpointId $endpointId to hash table"
                    $hashTableAdoResources.Add("$endpointId", $projSvcEndpoint)
                }
            }
        }
    }
    
    Write-Host "Writing all service connections to json"
    $allServiceConnectionsJson = $allServiceConnections | ConvertTo-Json -Depth $jsonDepth
    Set-Content -Value $allServiceConnectionsJson -Path $serviceConnectionJsonPath

    $exported = $true

    return $exported
}

function New-FederatedCredential {
    param (
        [Parameter(mandatory = $true)]
        [string] $organizationName,
        [Parameter(mandatory = $true)]
        [string] $projectName,
        [Parameter(mandatory = $true)]
        [string] $serviceConnectionName,
        [Parameter(mandatory = $true)]
        [string] $appObjectId,
        [Parameter(mandatory = $true)]
        [string] $endpointId,
        [Parameter(mandatory = $true)]
        [string] $organizationId
    )
    $minifiedString = Get-Content .\credential.template.json | Out-String
    $parametersJsonContent = (ConvertFrom-Json $minifiedString) | ConvertTo-Json -Depth 100 -Compress; #for PowerShell 7.3

    #$issuer = "https://vstoken.dev.azure.com/${organizationId}"
    $parametersJsonContent = $parametersJsonContent.Replace("__ENDPOINT_ID__", $endpointId)
    $parametersJsonContent = $parametersJsonContent.Replace("__ORGANIZATION_NAME__", $organizationName)
    $parametersJsonContent = $parametersJsonContent.Replace("__PROJECT_NAME__", $projectName)
    $parametersJsonContent = $parametersJsonContent.Replace("__SERVICE_CONNECTION_NAME__", $serviceConnectionName)
    $parametersJsonContent = $parametersJsonContent.Replace("__ORGANIZATION_ID__", $organizationId)

    Set-Content -Value $parametersJsonContent -Path .\credential.json

    $responseJson = az ad app federated-credential create --id $appObjectId --parameters credential.json

    return $responseJson
}

# This function pauses the script until the user presses a key.
function PauseOn {
    param (
        [bool] $boolValue
    )
    if ($boolValue) {
        Write-Host -NoNewLine 'Press any key to continue...';
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
        Write-Host  
    }
}

function ConvertTo-OrRevertFromWorkloadIdentityFederation {
    param (
        [string] $body,
        [string] $patTokenBase64,
        [string] $organizationName,
        [string] $endpointId
    )
    
    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Content-Type", "application/json")
    $headers.Add("Authorization", "Basic $patTokenBase64")    

    Try {
        # undocumented REST API call that is in preview
        $uri = "https://dev.azure.com/${organizationName}/_apis/serviceendpoint/endpoints/${endpointId}?operation=ConvertAuthenticationScheme&api-version=${apiVersion}"
        Write-Host "Trying url:"
        Write-Host $uri
        Write-Host
        Write-Host "Trying body:"
        Write-Host $body
        Write-Host
    
        $response = Invoke-RestMethod $uri -Method 'PUT' -Headers $headers -Body $body

        if ($response -is [string]) {
            if ($response.Contains("Azure DevOps Services | Sign In")) {
                Write-Warning "need to sign in - ensure it's the right tenant"
                PauseOn -boolValue (-not $skipPauseAfterError)
                return ""
            }
        }

        $responseJson = $response | ConvertTo-Json -Depth $jsonDepth        
    }
    Catch {
        if ($_.ErrorDetails.Message) {
            $errorMessage = $_.ErrorDetails.Message
            Write-Error $errorMessage
            
            #{"$id":"1","innerException":null,"message":"Converting endpoint type azurerm scheme from WorkloadIdentityFederation to WorkloadIdentityFederation is neither an upgrade or a downgrade and is not supported.","typeName":"System.ArgumentException, mscorlib","typeKey":"ArgumentException","errorCode":0,"eventId":0}
            if ($errorMessage.Contains("is neither an upgrade or a downgrade and is not supported")) {                
                PauseOn -boolValue (-not $skipPauseAfterError)
                return ""
            }
            elseif ($errorMessage.Contains("Azure Stack environment")) {
                #{"$id":"1","innerException":null,"message":"Unable to connect to the Azure Stack environment. Ignore the failure if the source is Azure DevOps.","typeName":"Microsoft.VisualStudio.Services.ServiceEndpoints.WebApi.ServiceEndpointException, Microsoft.VisualStudio.Services.ServiceEndpoints.WebApi","typeKey":"ServiceEndpointException","errorCode":0,"eventId":3000}
                PauseOn -boolValue (-not $skipPauseAfterError)
                return ""
            }
            else {
                throw "unhandled exception (unexpected exception)" # you may find more errors depending on your environment
            }
        }
        else {
            Write-Host $_
            throw "should NOT happen" # if it does - ensure you handle it appropriately
        }
    }

    return $responseJson
}

function Get-Body {
    param (
        [string] $id,
        [string] $type,
        [string] $authorizationScheme,
        [object] $serviceEndpointProjectReferences
    )

    # Create a custom object to hold the body of the request.
    $myBody = [PSCustomObject]@{
        id                               = $id
        type                             = $type
        authorization                    = [PSCustomObject]@{
            scheme = $authorizationScheme
        }
        serviceEndpointProjectReferences = @( $serviceEndpointProjectReferences ) # array
    }
    # Convert the custom object to JSON.
    $myBodyJson = $myBody | ConvertTo-Json -Depth $jsonDepth

    return $myBodyJson
}

function Get-Base64 {
    # Convert a string to Base64.
    param (
        [string] $patToken
    )
    # Convert to Base64.   
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("`:$patToken"))
}

function Get-PatTokenBase64 {
    param (
        [string] $tenantId
    )
    #Expecting an environment variable such as ADO-PAT-TOKEN-TENANT-a34*****-****-****-****-************
    
    Write-Host "ADO PAT is not set. Trying to get it from environment variable `"ADO-PAT-TOKEN-TENANT-$tenantId`" ..."
    $AdoPAT = [Environment]::GetEnvironmentVariable("ADO-PAT-TOKEN-TENANT-$tenantId", "User")  
    
    if (!$AdoPAT) {
        Write-Error "Could not find ADO PAT in environment variable `"ADO-PAT-TOKEN-TENANT-$tenantId`". Please set it and try again."
        return
    }
    else {
        Write-Host "Found ADO PAT in environment variable `"ADO-PAT-TOKEN-TENANT-$tenantId`"."
    }

    $AdoPATBase64 = Get-Base64 -patToken $AdoPAT
   
    return $AdoPATBase64
}

function Get-AuthenticodeMode {
    param (
        [object] $serviceConnection
    )
    $authorizationScheme = $($serviceConnection.authorization.scheme)
    $creationMode = $($serviceConnection.data.creationMode)

    if ($authorizationScheme -eq "WorkloadIdentityFederation") {
        return "Workload Identity Federation ($creationMode)"
    }
    elseif ($authorizationScheme -eq "ServicePrincipal") {
        return "Service Principal ($creationMode)"
    }
    elseif ($authorizationScheme -eq "ManagedServiceIdentity") {
        return "Managed Identity"
    }
    elseif ($authorizationScheme -eq "PublishProfile") {
        return "Publish Profile"
    }
    else {
        throw "Unexpected authorization scheme $authorizationScheme"
        return $authorizationScheme
    }
}

try {
    # STEP 1: Login to Azure and Get Service Connections

    Write-Host 'Login to your Azure account using az login (use an account that has access to your Microsoft Entra ID) ...'

    az account clear

    $login = az login --only-show-errors

    if (!$login) {
        Write-Error 'Error logging in and validating your credentials.'
        return;
    }

    $accountJson = az account show
    $account = $accountJson | ConvertFrom-Json
    $currentTenantId = $($account.tenantId)
    Write-Host "Current Tenant ID: $currentTenantId"

    Write-Host "Step 1: Get Service Connections using az devops CLI and export to JSON $serviceConnectionJsonPath ..."
    $serviceConnectionJsonPath = "../data/service_connections_${currentTenantId}.json"
    $exported = Get-ServiceConnections -serviceConnectionJsonPath $serviceConnectionJsonPath `
        -refreshServiceConnectionsIfTheyExist $refreshServiceConnectionsIfTheyExist `
        -tenantId $currentTenantId

    $hashTableAdoResourcesJson = $hashTableAdoResources | ConvertTo-Json -Depth $jsonDepth
    Set-Content -Value $hashTableAdoResourcesJson -Path "hashTableAdoResources.json"
}
catch {
    throw
}

if ($exported) {
    Write-Host 'Step 2: Loop through all service connections ...'

    $serviceConnectionJson = Get-Content -Path $serviceConnectionJsonPath -Raw

    $allServiceConnections = ConvertFrom-Json -InputObject $serviceConnectionJson -Depth $jsonDepth   

    foreach ($entry in $hashTableAdoResources.Values) {  
        
        $serviceConnection = $($entry.serviceEndpoint)
        $organizationName = $($entry.organizationName)
        $projectName = $($entry.projectName)
        $organizationId = $($entry.organizationId)

        $totalNumberOfArmServiceConnections++

        Write-Host "-----------------------"

        $applicationRegistrationClientId = $($serviceConnection.authorization.parameters.serviceprincipalid)
        Write-Host "App Registration Client Id   : $applicationRegistrationClientId"

        $tenantId = $($serviceConnection.authorization.parameters.tenantid)
        Write-Host "Tenant ID                    : $tenantId"
        Write-Host "Current AAD Tenant is        : $currentTenantId"
        Write-Host "Service Connection Tenant    : $tenantId"
        $tenantsMatch = $tenantId -eq $currentTenantId
        Write-Host "Tenants Match                : $tenantsMatch"

        $authorizationScheme = $($serviceConnection.authorization.scheme)
        Write-Host "Authorization Scheme         : $authorizationScheme"

        Write-Host "Organization                 : $organizationName"
        Write-Host "Organization ID              : $organizationId"
        Write-Host "Project                      : $projectName"
        $serviceConnectionName = $($serviceConnection.name)
        Write-Host "Service Connection Name      : $serviceConnectionName"
        $endpointId = $($serviceConnection.id)
        Write-Host "Endpoint ID                  : $endpointId"
        $revertSchemeDeadline = $($serviceConnection.data.revertSchemeDeadline)
        Write-Host "Revert Scheme Deadline       : $revertSchemeDeadline"
        $TimeSpan = $revertSchemeDeadline - (Get-Date -asUTC)
        if ($revertSchemeDeadline) {
            $totalDays = $TimeSpan.TotalDays        
        }
        else {
            $totalDays = 0
        }
        $canRevert = $totalDays -gt 0        
        if ($canRevert) {
            $foregroundColor = "Green"
        }
        else {
            $foregroundColor = "Red"
        }
        Write-Host "Can Revert                   : " -NoNewline
        Write-Host "$canRevert" -ForegroundColor $foregroundColor
        Write-Host "Total Days left to Revert    : $totalDays"
        
        $pauseNeeded = $false
        $creationMode = $($serviceConnection.data.creationMode)
        if ($creationMode -eq "Automatic") {
            $foregroundColor = "Green"
        }
        elseif ($creationMode -eq "Manual") {
            $foregroundColor = "Yellow"
        }
        elseif ($creationMode -eq "") {
            $foregroundColor = "Red"
            $creationMode = "<EMPTY>"
            $pauseNeeded = $true
        }
        else {
            Write-Host "Unexpected creation mode [${creationMode}]"
            throw "Unexpected creation mode [${creationMode}]"
        }
        Write-Host "Creation Mode                : " -NoNewline
        Write-Host "$creationMode" -ForegroundColor $foregroundColor
        if ($pauseNeeded) {
            PauseOn -boolValue (-not $skipPauseAfterError)
        }

        $AuthenticationMethod = Get-AuthenticodeMode -serviceConnection $serviceConnection
        Write-Host "Authentication Method        : $AuthenticationMethod"

        if ($AuthenticationMethod -eq "Workload Identity Federation (Automatic)") {
            $numberOfArmServiceConnectionsWithWorkloadIdentityFederationAutomatic++
        }
        elseif ($AuthenticationMethod -eq "Workload Identity Federation (Manual)") {
            $numberOfArmServiceConnectionsWithWorkloadIdentityFederationManual++
        }
        elseif ($AuthenticationMethod -eq "Service Principal (Automatic)") {
            $numberOfArmServiceConnectionsWithServicePrincipalAutomatic++
        }
        elseif ($AuthenticationMethod -eq "Service Principal (Manual)") {
            $numberOfArmServiceConnectionsWithServicePrincipalManual++
        }
        elseif ($AuthenticationMethod -eq "Managed Identity") {
            $numberOfArmServiceConnectionsWithManagedIdentity++
        }
        elseif ($AuthenticationMethod -eq "Publish Profile") {
            $numberOfArmServiceConnectionsWithPublishProfile++
        }
        else {
            throw "Unexpected authentication mode $AuthenticationMode"
        }

        $isShared = $($serviceConnection.isShared)
        Write-Host "Is Shared                    : $isShared"
        if ($isShared) {
            Write-Warning "connection is shared!"
            $numberOfSharedArmServiceConnections++
            PauseOn -boolValue (-not $skipPauseAfterWarning)
        }

        
        Write-Host "Body                         :"
        $serviceEndpointProjectReferences = $($serviceConnection.serviceEndpointProjectReferences)
        Write-Host $serviceEndpointProjectReferences
        $serviceEndpointProjectReferencesJson = $serviceEndpointProjectReferences | ConvertTo-Json
        Write-Host $serviceEndpointProjectReferencesJson

        $refCount = $serviceEndpointProjectReferences.Length
        Write-Host "Number of Project Refs       : $refCount"
        if ($refCount -eq 1) {
            # Write-Host "expected"
        }
        else {
            Write-Warning "Shared Service Connections are discouraged. This one is shared with $refCount projects."
            PauseOn -boolValue (-not $skipPauseAfterWarning)
        }

        $id = $($serviceConnection.id)
        $type = $($serviceConnection.type)
        $myBodyJson = Get-Body -id $id `
            -type $type `
            -authorizationScheme $authorizationScheme `
            -serviceEndpointProjectReferences $serviceEndpointProjectReferences
        Write-Host $myBodyJson

        #common
        $patTokenBase64 = Get-PatTokenBase64 -tenantId $tenantId  
        if ($authorizationScheme -eq "ServicePrincipal") {
            $destinationAuthorizationScheme = "WorkloadIdentityFederation"
        }
        elseif ($authorizationScheme -eq "WorkloadIdentityFederation") {
            $destinationAuthorizationScheme = "ServicePrincipal"
        }   
        else {
            Write-Warning "Unexpected authorization scheme $authorizationScheme - will not convert (or revert)"
        }
        $myNewBodyJson = Get-Body -id $id `
            -type $type `
            -authorizationScheme $destinationAuthorizationScheme `
            -serviceEndpointProjectReferences $serviceEndpointProjectReferences  

        if ($revertAll) {
            if ($authorizationScheme -eq "WorkloadIdentityFederation") {
                Write-Host "Found workload identity service connection - analyzing if it's a candidate to revert"   
                if ($isProductionRun -and $tenantsMatch) {
                    if ($canRevert) {
                        $responseJson = ConvertTo-OrRevertFromWorkloadIdentityFederation -body $myNewBodyJson `
                            -organizationName $organizationName `
                            -endpointId $endpointId `
                            -patTokenBase64 $patTokenBase64
                        if ($responseJson) {
                            Write-Host "Call was successful and returned JSON response:"
                            Write-Host $responseJson
                            Write-Host "Reverted service connection!"
                            $totalNumberOfArmServiceConnectionWithWorkloadIdentityFederationRevertedBackToServicePrincipal++
                            PauseOn -boolValue (-not $skipPauseAfterError)
                        }
                        else {
                            Write-Warning "Got empty response (check above for message) so moving on..."
                            $totalNumberOfArmServiceConnectionWithWorkloadIdentityFederationThatDidNotRevertBackToServicePrincipal++
                        }
                    }
                    else {
                        Write-Warning "Cannot revert since deadline has passed"
                    }
                }
                else {
                    if (-not $isProductionRun) {
                        Write-Host "Skipping reverting since not a production run"
                    }
                    else {
                        Write-Host "tenants do NOT match so skipping reverting"
                    }
                }        
            }
        }
        else {        
            if ($authorizationScheme -eq "ServicePrincipal") {            
                Write-Host "Found Service Principal - analyzing if it's a candidate to convert"            
                if ($isProductionRun -and $tenantsMatch) {
                    if ($creationMode -eq "Manual") {
                        Write-Host "Need to create fed cred for Manual Svc Conn"
                        # $organizationId = Get-OrganizationId -tenantId $tenantId `
                        #     -organizationName $organizationName

                        if ($organizationId) {
                            $existingFedCredsJson = az ad app federated-credential list --id  $applicationRegistrationClientId 
                            $existingFedCreds = $existingFedCredsJson | ConvertFrom-Json
                            $subject = "sc://$organizationName/$projectName/$serviceConnectionName"
                            $matchingCred = $existingFedCreds | Where-Object { $_.Subject -eq $subject }
                            if ($matchingCred) {
                                Write-Host "cred with subject $subject ALREADY exists!"
                                Write-Host $matchingCred 
                            }
                            else {
                                Write-Warning "cred with subject $subject does not exist! Creating it now..."               

                                $responseJson = New-FederatedCredential -organizationName $organizationName `
                                    -projectName $projectName `
                                    -organizationId $organizationId `
                                    -serviceConnectionName $serviceConnectionName `
                                    -endpointId $endpointId `
                                    -appObjectId $applicationRegistrationClientId
                            
                                if ($responseJson) {
                                    $numberOfFederatedCredentialsCreatedManually++
                                }

                                PauseOn -boolValue (-not $skipPauseAfterError)
                            }
                        
                        }
                        else {
                            Write-Warning "Skipping creation of fed cred since we did not find org id in tenant"
                        }
                    }
                    $responseJson = ConvertTo-OrRevertFromWorkloadIdentityFederation -body $myNewBodyJson `
                        -organizationName $organizationName `
                        -endpointId $endpointId `
                        -patTokenBase64 $patTokenBase64
                    if ($responseJson) {
                        Write-Host "Call was successful and returned JSON response:"
                        Write-Host $responseJson
                        Write-Host "Converted service connection!"
                        $totalNumberOfArmServiceConnectionWithServicePrincipalConvertedToWorkloadIdentityFederation++
                        PauseOn -boolValue (-not $skipPauseAfterError)
                    }
                    else {
                        Write-Warning "Got empty response (check above for message) so moving on..."
                        $totalNumberOfArmServiceConnectionWithServicePrincipalThatDidNotConvertToWorkloadIdentityFederation++
                    }
                }
                else {
                    if (-not $isProductionRun) {
                        Write-Host "Skipping conversion since not a production run"
                    }
                    else {
                        Write-Host "tenants do NOT match so skipping conversion"
                    }
                }
            }
        }
        

        Write-Host "-----------------------"

        Write-Host
        Write-Host "ARM SC with Workload Identity Federation (Automatic)                     : $numberOfArmServiceConnectionsWithWorkloadIdentityFederationAutomatic"
        Write-Host "ARM SC with Workload Identity Federation (Manual)                        : $numberOfArmServiceConnectionsWithWorkloadIdentityFederationManual"
        Write-Host "ARM SC with Service Principal (Automatic)                                : $numberOfArmServiceConnectionsWithServicePrincipalAutomatic"
        Write-Host "ARM SC with Service Principal (Manual)                                   : $numberOfArmServiceConnectionsWithServicePrincipalManual"
        Write-Host "ARM SC with Managed Identity                                             : $numberOfArmServiceConnectionsWithManagedIdentity"
        Write-Host "ARM SC with Publish Profile                                              : $numberOfArmServiceConnectionsWithPublishProfile"
        Write-Host
        Write-Host "Total Number of Arm Service Connections                                  : $totalNumberOfArmServiceConnections"
        Write-Host
        Write-Host "Total Number of Arm Service Connections Converted                        : $totalNumberOfArmServiceConnectionWithServicePrincipalConvertedToWorkloadIdentityFederation"
        Write-Host "Total Number of Arm Service Connections That did NOT Convert             : $totalNumberOfArmServiceConnectionWithServicePrincipalThatDidNotConvertToWorkloadIdentityFederation"
        Write-Host
        Write-Host "Total Number of Arm Service Connections Reverted                         : $totalNumberOfArmServiceConnectionWithWorkloadIdentityFederationRevertedBackToServicePrincipal"
        Write-Host "Total Number of Arm Service Connections That did NOT revert              : $totalNumberOfArmServiceConnectionWithWorkloadIdentityFederationThatDidNotRevertBackToServicePrincipal"
        Write-Host
        Write-Host "Number Of Federated Credentials Created Manually                         : $numberOfFederatedCredentialsCreatedManually"
        Write-Host "Number Of Shared Arm Service Connections                                 : $numberOfSharedArmServiceConnections"
    }
}