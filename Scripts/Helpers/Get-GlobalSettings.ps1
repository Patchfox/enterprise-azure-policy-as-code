#Requires -PSEdition Core

function Get-GlobalSettings {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)] [string] $definitionsRootFolder,
        [Parameter(Mandatory = $false)] [string] $outputFolder,
        [Parameter(Mandatory = $false)] [string] $inputFolder
    )

    # Callcuate folders
    $folders = Get-PacFolders `
        -definitionsRootFolder $definitionsRootFolder `
        -outputFolder $outputFolder `
        -inputFolder $inputFolder

    $definitionsRootFolder = $folders.definitionsRootFolder
    $outputFolder = $folders.outputFolder
    $inputFolder = $folders.inputFolder
    $globalSettingsFile = $folders.globalSettingsFile

    Write-Information ""
    Write-Information "==================================================================================================="
    Write-Information "Read global settings from '$globalSettingsFile'."
    Write-Information "==================================================================================================="

    $Json = Get-Content -Path $globalSettingsFile -Raw -ErrorAction Stop
    if (!(Test-Json $Json)) {
        Write-Error "JSON file ""$($globalSettingsFile)"" is not valid = $Json" -ErrorAction Stop
    }
    [hashtable] $settings = $Json | ConvertFrom-Json -AsHashtable
    [array] $pacEnvironments = $settings.pacEnvironments
    [hashtable] $pacEnvironmentDefinitions = @{}
    [string[]] $pacEnvironmentSelectors = @()
    $pacOwnerId = $settings.pacOwnerId
    if ($null -eq $pacOwnerId) {
        Write-Error "global-settings does not contain a pacOwnerId. Add a pacOwnerId field with a GUID or other unique id!" -ErrorAction Stop
    }

    foreach ($pacEnvironment in $pacEnvironments) {

        $pacSelector = $pacEnvironment.pacSelector
        if ($null -eq $pacSelector) {
            Write-Error "Policy as Code pacEnvironments array element does not contain a pacSelector." -ErrorAction Stop
        }
        $pacEnvironmentSelectors += $pacSelector

        $cloud = $pacEnvironment.cloud
        if ($null -eq $cloud) {
            Write-Warning "Policy as Code environment $pacSelector does not define the cloud to use, default to 'AzureCloud'"
            $cloud = "AzureCloud"
        }

        $tenantId = $pacEnvironment.tenantId
        if ($null -eq $tenantId) {
            Write-Error "Policy as Code environment $pacSelector does not contain a tenantId." -ErrorAction Stop
        }

        $defaultSubscriptionId = $pacEnvironment.defaultSubscriptionId
        if ($null -ne $defaultSubscriptionId) {
            Write-Warning "Policy as Code environment $pacSelector contains a legacy defaultSubscriptionId. Remove it!" -ErrorAction Stop
        }
        if ($null -ne $pacEnvironment.rootScope) {
            Write-Error "Policy as Code environment $pacSelector contains a legacy rootScope. Replace rootScope with deploymentRootScope containing a fully qualified scope id!" -ErrorAction Stop
        }

        $policyDefinitionsScopes = @()
        $deploymentRootScope = $null
        if ($null -ne $pacEnvironment.deploymentRootScope) {
            $deploymentRootScope = $pacEnvironment.deploymentRootScope
            $policyDefinitionsScopes += $deploymentRootScope

            if ($null -ne $pacEnvironment.inheritedDefinitionsScopes) {
                $inheritedDefinitionsScopes = $pacEnvironment.inheritedDefinitionsScopes
                if ($inheritedDefinitionsScopes -isnot [array]) {
                    Write-Error "Policy as Code environment $pacSelector element inheritedDefinitionsScopes must be an array of strings." -ErrorAction Stop
                }
                $policyDefinitionsScopes += $inheritedDefinitionsScopes
            }
            $policyDefinitionsScopes += ""
        }
        else {
            Write-Error "Policy as Code environment $pacSelector must contain a deploymentRootScope field." -ErrorAction Stop
        }

        # globalNotScopes
        [array] $globalNotScopeList = @()
        if ($null -eq $settings.globalNotScopes) {
            Write-Warning "No global Not Scope defined in global-settings.jsonc, default is an empty list."
        }
        else {
            $globalNotScopes = $settings.globalNotScopes
            if ($globalNotScopes.ContainsKey($pacSelector)) {
                $globalNotScopeList += $globalNotScopes[$pacSelector]
            }
            if ($globalNotScopes.ContainsKey("*")) {
                $globalNotScopeList += $globalNotScopes["*"]
            }
        }

        $desiredState = @{ # defaults
            strategy                     = "full" # Mirrors previous behavior (before desireState feature). -NoDelete would be equivalent to ownedOnly
            includeResourceGroups        = $false # Mirrors previous behavior (before desireState feature). -IncludeResourceGroups would be equivalent to $true
            excludedScopes               = [System.Collections.ArrayList]::new()
            excludedPolicyDefinitions    = @()
            excludedPolicySetDefinitions = @()
            excludedPolicyAssignments    = @()
        }
        if ($null -ne $pacEnvironment.desiredState) {
            $desired = $pacEnvironment.desiredState
            $strategy = $desired.strategy
            if ($null -ne $strategy) {
                $valid = @("full", "ownedOnly")
                if ($strategy -notin $valid) {
                    Write-Error "Policy as Code environment $pacSelector field desiredState.strategy ($strategy) must be one of $(ConvertTo-Json $valid -Compress)." -ErrorAction Stop
                }
                $desiredState.strategy = $strategy
            }
            $includeResourceGroups = $desired.includeResourceGroups
            if ($null -ne $includeResourceGroups) {
                if ($includeResourceGroups -is [bool]) {
                    $desiredState.includeResourceGroups = $includeResourceGroups
                }
                else {
                    Write-Error "Policy as Code environment $pacSelector field desiredState.includeResourceGroups ($includeResourceGroups) must be a boolean value." -ErrorAction Stop
                }
            }
            $excluded = $desired.excludedScopes
            if ($null -ne $excluded) {
                if ($excluded -isnot [array]) {
                    Write-Error "Policy as Code environment $pacSelector field desiredState.excludedScopes ($(ConvertTo-Json $excluded -Compress)) must be an array of strings." -ErrorAction Stop
                }
                foreach ($entry in $excluded) {
                    if ($null -ne $entry -and $entry -is [string] -and $entry -ne "") {
                        $null = $desiredState.excludedScopes.Add($entry)
                    }
                }
            }
            $excluded = $desired.excludedPolicyDefinitions
            if ($null -ne $excluded) {
                if ($excluded -isnot [array]) {
                    Write-Error "Policy as Code environment $pacSelector field desiredState.excludedPolicyDefinitions ($(ConvertTo-Json $excluded -Compress)) must be an array of strings." -ErrorAction Stop
                }
                $desiredState.excludedPolicyDefinitions = $excluded
            }
            $excluded = $desired.excludedPolicySetDefinitions
            if ($null -ne $excluded) {
                if ($excluded -isnot [array]) {
                    Write-Error "Policy as Code environment $pacSelector field desiredState.excludedPolicySetDefinitions ($(ConvertTo-Json $excluded -Compress)) must be an array of strings." -ErrorAction Stop
                }
                $desiredState.excludedPolicySetDefinitions = $excluded
            }
            $excluded = $desired.excludedPolicyAssignments
            if ($null -ne $excluded) {
                if ($excluded -isnot [array]) {
                    Write-Error "Policy as Code environment $pacSelector field desiredState.excludedPolicyAssignments ($(ConvertTo-Json $excluded -Compress)) must be an array of strings." -ErrorAction Stop
                }
                $desiredState.excludedPolicyAssignments = $excluded
            }
        }
        foreach ($entry in $globalNotScopeList) {
            if ($null -ne $entry -and $entry -ne "" -and !$entry.Contains("*")) {
                $null = $desiredState.excludedScopes.Add($entry)
            }
        }

        # Managed identity location
        $managedIdentityLocation = $null
        if ($settings.managedIdentityLocations) {
            $managedIdentityLocations = $settings.managedIdentityLocations
            if ($managedIdentityLocations.ContainsKey($pacSelector)) {
                $managedIdentityLocation = $managedIdentityLocations[$pacSelector]
            }
            elseif ($managedIdentityLocations.ContainsKey("*")) {
                $managedIdentityLocation = $managedIdentityLocations["*"]

            }
        }
        $null = $pacEnvironmentDefinitions.Add($pacSelector, @{
                pacSelector             = $pacSelector
                pacOwnerId              = $pacOwnerId
                cloud                   = $cloud
                tenantId                = $tenantId
                deploymentRootScope     = $deploymentRootScope
                policyDefinitionsScopes = $policyDefinitionsScopes
                desiredState            = $desiredState
                globalNotScopes         = $globalNotScopeList
                managedIdentityLocation = $managedIdentityLocation
            }
        )
    }
    $prompt = $pacEnvironmentSelectors | Join-String -Separator ', '

    Write-Information "PAC Environments: $($prompt)"
    Write-Information "Definitions root folder: $definitionsRootFolder"
    Write-Information "Input folder: $inputFolder"
    Write-Information "Output folder: $outputFolder"
    Write-Information ""

    $policyDocumentationsFolder = "$definitionsRootFolder/policyDocumentations"
    if (!(Test-Path $policyDocumentationsFolder -PathType Container)) {
        $policyDocumentationsFolder1 = "$definitionsRootFolder/DocumentationSpecs" # Legacy location
        $policyDocumentationsFolder2 = "$definitionsRootFolder/Documentation"
        if (Test-Path $policyDocumentationsFolder1 -PathType Container) {
            Write-Error "Legacy documentation definition folder name 'DocumentationSpecs' used. Rename to 'policyDocumentations'!"  -ErrorAction Stop
        }
        elseif (Test-Path $policyDocumentationsFolder2 -PathType Container) {
            Write-Error "Legacy documentation definition folder name 'Documentation' used. Rename to 'policyDocumentations'!"  -ErrorAction Stop
        }
    }

    $policyDefinitionsFolder = "$definitionsRootFolder/policyDefinitions"
    if (!(Test-Path $policyDefinitionsFolder -PathType Container)) {
        $policyDefinitionsFolder = # Legacy location
        if ((Test-Path "$definitionsRootFolder/Policies" -PathType Container)) {
            Write-Error "Legacy Policy definitions folder name 'Policies' used. Rename to 'policyDefinitions'!" -ErrorAction Stop
        }
        else {
            Write-Error "Policy definitions 'policyDefinitions' folder not found."  -ErrorAction Stop
        }
    }

    $policySetDefinitionsFolder = "$definitionsRootFolder/policySetDefinitions"
    if (!(Test-Path $policySetDefinitionsFolder -PathType Container)) {
        $policySetDefinitionsFolder = "$definitionsRootFolder/Initiatives" # Legacy location
        if ((Test-Path $policySetDefinitionsFolder -PathType Container)) {
            Write-Error "Legacy Policy Set definitions folder name Initiatives used. Rename to 'policySetDefinitions'!" -ErrorAction Stop
        }
        else {
            Write-Error "Policy Set definitions folder 'policySetDefinitions' not found." -ErrorAction Stop
        }
    }

    $policyAssignmentsFolder = "$definitionsRootFolder/policyAssignments"
    if (!(Test-Path $policyAssignmentsFolder -PathType Container)) {
        $policyAssignmentsFolder = "$definitionsRootFolder/Assignments" # Legacy location
        if ((Test-Path $policyAssignmentsFolder -PathType Container)) {
            Write-Error "Legacy Policy Assignments folder name 'Assignments' used. Rename to 'policyAssignments'!" -ErrorAction Stop
        }
        else {
            Write-Error "Policy Assignments folder 'policyAssignments' not found." -ErrorAction Stop
        }
    }

    $policyExemptionsFolder = "$definitionsRootFolder/policyExemptions"
    if (!(Test-Path $policyExemptionsFolder -PathType Container)) {
        $policyExemptionsFolder = "$definitionsRootFolder/Exemptions" # Legacy location
        if ((Test-Path $policyExemptionsFolder -PathType Container)) {
            Write-Error "Legacy Policy Exemptions folder name 'policyExemptions' used. Rename to 'policyExemptions'!" -ErrorAction Stop
        }
    }

    [hashtable] $globalSettings = @{
        definitionsRootFolder      = $definitionsRootFolder
        globalSettingsFile         = $globalSettingsFile
        outputFolder               = $outputFolder
        inputFolder                = $inputFolder
        policyDocumentationsFolder = $policyDocumentationsFolder
        policyDefinitionsFolder    = $policyDefinitionsFolder
        policySetDefinitionsFolder = $policySetDefinitionsFolder
        policyAssignmentsFolder    = $policyAssignmentsFolder
        policyExemptionsFolder     = $policyExemptionsFolder
        pacEnvironmentSelectors    = $pacEnvironmentSelectors
        pacEnvironmentPrompt       = $prompt
        pacEnvironments            = $pacEnvironmentDefinitions
    }
    return $globalSettings
}
