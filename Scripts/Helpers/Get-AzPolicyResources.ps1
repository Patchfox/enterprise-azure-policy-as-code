#Requires -PSEdition Core

function Set-UniqueRoleAssignmentScopes {
    [CmdletBinding()]
    param (
        [string] $scopeId,
        [hashtable] $uniqueRoleAssignmentScopes
    )

    $splits = $scopeId -split "/"
    $segments = $splits.Length

    $scopeType = switch ($segments) {
        3 {
            "subscriptions"
            break
        }
        5 {
            $splits[3]
            break
        }
        { $_ -gt 5 } {
            "resources"
            break
        }
        Default { "unknown" }
    }
    $table = $uniqueRoleAssignmentScopes.$scopeType
    $table[$scopeId] = $scopeType
}

function Confirm-PolicyResourceExclusions {
    [CmdletBinding()]
    param (
        $testId,
        $resourceId,
        $policyResource,
        $scopeTable,
        $includeResourceGroups,
        $excludedScopes,
        $excludedIds,
        $policyResourceTable
    )

    $resourceIdParts = Split-AzPolicyResourceId -id $testId
    $scope = $resourceIdParts.scope
    $scopeType = $resourceIdParts.scopeType

    if ($scopeType -eq "builtin") {
        return $true, $resourceIdParts
    }
    if (!$scopeTable.ContainsKey($scope)) {
        $policyResourceTable.counters.unMangedScope += 1
        $null = $policyResourceTable.excluded.Add($resourceId, $policyResource)
        return $false, $resourceIdParts
    }
    $scopeEntry = $scopeTable.$scope
    $parentList = $scopeEntry.parentList
    if ($null -eq $parentList) {
        Write-Error "Code bug parentList is $null $($scopeEntry | ConvertTo-Json -Depth 100 -Compress)"
    }
    if (!$includeResourceGroups -and $scopeType -eq "resourceGroups") {
        # Write-Information "    Exclude(resourceGroup) $($resourceId)"
        $policyResourceTable.counters.excludedScopes += 1
        $null = $policyResourceTable.excluded.Add($resourceId, $policyResource)
        return $false, $resourceIdParts
    }
    foreach ($testScope in $excludedScopes) {
        if ($scope -eq $testScope -or $parentList.ContainsKey($testScope)) {
            # Write-Information "Exclude(scope,$testScope) $($resourceId)"
            $policyResourceTable.counters.excludedScopes += 1
            $null = $policyResourceTable.excluded.Add($resourceId, $policyResource)
            return $false, $resourceIdParts
        }
    }
    foreach ($testExcludedId in $excludedIds) {
        if ($testId -like $testExcludedId) {
            Write-Information "Exclude(id,$testExcludedId) $($resourceId)"
            $policyResourceTable.counters.excluded += 1
            $null = $policyResourceTable.excluded.Add($resourceId, $policyResource)
            return $false, $resourceIdParts
        }
    }
    return $true, $resourceIdParts
}

function Get-AzPolicyResources {
    [CmdletBinding()]
    param (
        [hashtable] $pacEnvironment,
        [hashtable] $scopeTable,

        [switch] $skipRoleAssignments,
        [switch] $skipExemptions,
        [switch] $collectRemediations,
        [switch] $collectAllPolicies
    )

    $deploymentRootScope = $pacEnvironment.deploymentRootScope
    $tenantId = $pacEnvironment.tenantId
    Write-Information "==================================================================================================="
    Write-Information "Get Policy Resources for $($deploymentRootScope -replace '/providers/Microsoft.Management','')"
    Write-Information "==================================================================================================="
    $prefBackup = $WarningPreference
    $WarningPreference = 'SilentlyContinue'
    $policyResources = Search-AzGraphAllItems `
        -query 'PolicyResources | where (type == "microsoft.authorization/policyassignments") or (type == "microsoft.authorization/policysetdefinitions") or (type == "microsoft.authorization/policydefinitions")' `
        -scope @{ UseTenantScope = $true }
    $WarningPreference = $prefBackup

    Write-Information "Processing $($policyResources.Count) Policy resources (Policy assignments, Policy Set (Initiative) and Policy definitions):"
    $deployed = @{
        policydefinitions            = @{
            all      = @{}
            readOnly = @{}
            managed  = @{}
            excluded = @{}
            counters = @{
                builtIn       = 0
                inherited     = 0
                managedBy     = @{
                    thisPaC  = 0
                    otherPaC = 0
                    unknown  = 0
                }
                excluded      = 0
                unMangedScope = 0
            }
        }
        policysetdefinitions         = @{
            all      = @{}
            readOnly = @{}
            managed  = @{}
            excluded = @{}
            counters = @{
                builtIn       = 0
                inherited     = 0
                managedBy     = @{
                    thisPaC  = 0
                    otherPaC = 0
                    unknown  = 0
                }
                excluded      = 0
                unMangedScope = 0
            }
        }
        policyassignments            = @{
            all      = @{}
            managed  = @{}
            excluded = @{}
            counters = @{
                managedBy      = @{
                    thisPaC  = 0
                    otherPaC = 0
                    unknown  = 0
                }
                excludedScopes = 0
                excluded       = 0
                unMangedScope  = 0
            }
        }
        roleAssignmentsByPrincipalId = @{}
        policyExemptions             = @{
            all      = @{}
            managed  = @{}
            excluded = @{}
            orphaned = @{}
            counters = @{
                managedBy = @{
                    thisPaC  = 0
                    otherPaC = 0
                    unknown  = 0
                }
            }
        }
        nonComplianceSummary         = @{}
        remediationTasks             = @{}
    }

    $desiredState = $pacEnvironment.desiredState
    $includeResourceGroups = $desiredState.includeResourceGroups
    $excludedPolicyAssignments = $desiredState.excludedPolicyAssignments
    $excludedScopes = $desiredState.excludedScopes
    $policyDefinitionsScopes = $pacEnvironment.policyDefinitionsScopes
    $scopesLength = $policyDefinitionsScopes.Length
    $scopesLast = $scopesLength - 1
    $policyAssignmentsTable = $deployed.policyassignments
    $thisPacOwnerId = $pacEnvironment.pacOwnerId
    $uniqueRoleAssignmentScopes = @{
        resources        = @{}
        resourceGroups   = @{}
        subscriptions    = @{}
        managementGroups = @{}
    }
    $uniquePrincipalIds = @{}
    $assignmentsWithIdentity = @{}
    foreach ($policyResourceRaw in $policyResources) {
        $thisTenantId = $policyResourceRaw.tenantId
        if ($thisTenantId -in @("", $tenantId)) {
            $policyResource = Get-HashtableShallowClone $policyResourceRaw
            $id = $policyResource.id
            $kind = $policyResource.kind
            $included = $true
            $resourceIdParts = $null
            if ($kind -eq "policyassignments") {
                if ($collectAllPolicies) {
                    $policyResource.pacOwner = Confirm-PacOwner -thisPacOwnerId $thisPacOwnerId -metadata $policyResource.properties.metadata -managedByCounters $policyAssignmentsTable.counters.managedBy
                    $null = $policyAssignmentsTable.all.Add($id, $policyResource)
                }
                else {
                    $included, $resourceIdParts = Confirm-PolicyResourceExclusions `
                        -testId $id `
                        -resourceId $id `
                        -policyResource $policyResource `
                        -scopeTable $scopeTable `
                        -includeResourceGroups $includeResourceGroups `
                        -excludedScopes $excludedScopes `
                        -excludedIds $excludedPolicyAssignments `
                        -policyResourceTable $policyAssignmentsTable
                    if ($included) {
                        $scope = $resourceIdParts.scope
                        $policyResource.pacOwner = Confirm-PacOwner -thisPacOwnerId $thisPacOwnerId -metadata $policyResource.properties.metadata -managedByCounters $policyAssignmentsTable.counters.managedBy
                        $null = $policyAssignmentsTable.all.Add($id, $policyResource)
                        $null = $policyAssignmentsTable.managed.Add($id, $policyResource)
                        if ($policyResource.identity) {
                            $principalId = $policyResource.identity.principalId
                            $null = $assignmentsWithIdentity.Add($id, $policyResource)
                            Set-UniqueRoleAssignmentScopes `
                                -scopeId $scope `
                                -uniqueRoleAssignmentScopes $uniqueRoleAssignmentScopes
                            $uniquePrincipalIds[$principalId] = $true
                            if ($policyResource.properties.metadata.roles) {
                                $roles = $policyResource.properties.metadata.roles
                                foreach ($role in $roles) {
                                    Set-UniqueRoleAssignmentScopes `
                                        -scopeId $role.scope `
                                        -uniqueRoleAssignmentScopes $uniqueRoleAssignmentScopes
                                }
                            }
                        }
                    }
                }
            }
            else {
                $deployedPolicyTable = $deployed.$kind
                $found = $false
                if ($collectAllPolicies) {
                    if ($policyResource.policyType -eq "Custom") {
                        $policyResource.pacOwner = Confirm-PacOwner -thisPacOwnerId $thisPacOwnerId -metadata $policyResource.properties.metadata -managedByCounters $deployedPolicyTable.counters.managedBy
                        $null = $deployedPolicyTable.all.Add($id, $policyResource)
                    }
                }
                else {
                    $excludedList = $desiredState.excludedPolicyDefinitions
                    if ($kind -eq "policysetdefinitions") {
                        $excludedList = $desiredState.excludedPolicySetDefinitions
                    }
                    $included, $resourceIdParts = Confirm-PolicyResourceExclusions `
                        -testId $id `
                        -resourceId $id `
                        -policyResource $policyResource `
                        -scopeTable $scopeTable `
                        -includeResourceGroups $includeResourceGroups `
                        -excludedScopes @() `
                        -excludedIds $excludedList `
                        -policyResourceTable $policyAssignmentsTable
                    if ($included) {
                        for ($i = 0; $i -lt $scopesLength -and !$found; $i++) {
                            $currentScopeId = $policyDefinitionsScopes[$i]
                            if ($resourceIdParts.scope -eq $currentScopeId) {
                                switch ($i) {
                                    0 {
                                        # deploymentRootScope
                                        $null = $deployedPolicyTable.all.Add($id, $policyResource)
                                        $null = $deployedPolicyTable.managed.Add($id, $policyResource)
                                        $policyResource.pacOwner = Confirm-PacOwner -thisPacOwnerId $thisPacOwnerId -metadata $policyResource.properties.metadata -managedByCounters $deployedPolicyTable.counters.managedBy
                                        $found = $true
                                    }
                                    $scopesLast {
                                        # BuiltIn or Static, since last entry in array is empty string ($currentPolicyDefinitionsScopeId)
                                        $null = $deployedPolicyTable.all.Add($id, $policyResource)
                                        $null = $deployedPolicyTable.readOnly.Add($id, $policyResource)
                                        $deployedPolicyTable.counters.builtIn += 1
                                        $found = $true
                                    }
                                    Default {
                                        # Read only definitions scopes
                                        $null = $deployedPolicyTable.all.Add($id, $policyResource)
                                        $null = $policyDefinitions.readOnly.Add($id, $policyResource)
                                        $deployedPolicyTable.counters.inherited += 1
                                        $found = $true
                                    }
                                }
                            }
                        }
                        if (!$found) {
                            $deployedPolicyTable.counters.unMangedScope += 1
                        }
                    }
                }
            }
        }
    }

    foreach ($kind in @("policydefinitions", "policysetdefinitions")) {
        $deployedPolicyTable = $deployed.$kind
        $counters = $deployedPolicyTable.counters
        $managedBy = $counters.managedBy
        $managedByAny = $managedBy.thisPaC + $managedBy.otherPaC + $managedBy.unknown
        Write-Information ""
        if ($kind -eq "policydefinitions") {
            Write-Information "Policy definitions counts:"
        }
        else {
            Write-Information "Policy Set (Initiative) definitions counts:"
        }
        if ($collectAllPolicies) {
            Write-Information "    Custom (all)   = $($deployedPolicyTable.all.Count)"
            Write-Information "    Managed ($($managedByAny)) by:"
            Write-Information "        This PaC   = $($managedBy.thisPaC)"
            Write-Information "        Other PaC  = $($managedBy.otherPaC)"
            Write-Information "        Unknown    = $($managedBy.unknown)"
        }
        else {
            Write-Information "    BuiltIn        = $($counters.builtIn)"
            Write-Information "    Managed ($($managedByAny)) by:"
            Write-Information "        This PaC   = $($managedBy.thisPaC)"
            Write-Information "        Other PaC  = $($managedBy.otherPaC)"
            Write-Information "        Unknown    = $($managedBy.unknown)"
            Write-Information "    Inherited      = $($counters.inherited)"
            Write-Information "    Excluded       = $($counters.excluded)"
            Write-Information "    Not our scopes = $($counters.unMangedScope)"
        }
    }

    $counters = $deployed.policyassignments.counters
    $managedBy = $counters.managedBy
    $managedByAny = $managedBy.thisPaC + $managedBy.otherPaC + $managedBy.unknown
    Write-Information ""
    Write-Information "Policy Assignments:"
    Write-Information "    Managed ($($managedByAny)) by:"
    Write-Information "        This PaC    = $($managedBy.thisPaC)"
    Write-Information "        Other PaC   = $($managedBy.otherPaC)"
    Write-Information "        Unknown     = $($managedBy.unknown)"
    Write-Information "    With identity   = $($assignmentsWithIdentity.Count)"
    Write-Information "    Excluded scopes = $($counters.excludedScopes)"
    Write-Information "    Excluded        = $($counters.excluded)"
    Write-Information "    Not our scopes  = $($counters.unMangedScope)"

    if (!$skipRoleAssignments) {
        # Get-AzRoleAssignment from the lowest scopes up. This will reduce the number of calls to Azure
        $roleAssignmentsById = @{}
        $scopesCovered = @{}
        $scopesCollectedCount = 0
        $roleAssignmentsCount = 0
        # Write-Information "    Progress:"
        # individual resources
        Write-Information ""
        Write-Information "Collecting Role assignments (this may take a while):"
        foreach ($scope in $uniqueRoleAssignmentScopes.resources.Keys) {
            if (!$scopesCovered.ContainsKey($scope)) {
                $scopesCovered[$scope] = $true
                $results = @()
                $scopesCollectedCount++
                Write-Information "    $scope"
                $results += Get-AzRoleAssignment -Scope $scope -WarningAction SilentlyContinue
                $localScopesCovered = @{}
                foreach ($result in $results) {
                    if ($result.ObjectType -eq "ServicePrincipal" -and $uniquePrincipalIds.ContainsKey($result.ObjectId)) {
                        $localScopesCovered[$result.Scope] = $true
                        $roleAssignmentsById[$result.RoleAssignmentId] = $result
                        $roleAssignmentsCount++
                    }
                }
                foreach ($localScope in $localScopesCovered.Keys) {
                    $scopesCovered[$localScope] = $true
                }
            }
        }
        # resource groups
        foreach ($scope in $uniqueRoleAssignmentScopes.resourceGroups.Keys) {
            if (!$scopesCovered.ContainsKey($scope)) {
                $scopesCovered[$scope] = $true
                $results = @()
                Write-Information "    $scope"
                $results += Get-AzRoleAssignment -Scope $scope -WarningAction SilentlyContinue
                $scopesCollectedCount++
                $localScopesCovered = @{}
                foreach ($result in $results) {
                    if ($result.ObjectType -eq "ServicePrincipal" -and $uniquePrincipalIds.ContainsKey($result.ObjectId)) {
                        $localScopesCovered[$result.Scope] = $true
                        $roleAssignmentsById[$result.RoleAssignmentId] = $result
                        $roleAssignmentsCount++
                    }
                }
                foreach ($localScope in $localScopesCovered.Keys) {
                    $scopesCovered[$localScope] = $true
                }
            }
        }
        # subscriptions
        foreach ($scope in $uniqueRoleAssignmentScopes.subscriptions.Keys) {
            if (!$scopesCovered.ContainsKey($scope)) {
                $scopesCovered[$scope] = $true
                $results = @()
                Write-Information "    $scope"
                $results += Get-AzRoleAssignment -Scope $scope -WarningAction SilentlyContinue
                $scopesCollectedCount++
                $localScopesCovered = @{}
                foreach ($result in $results) {
                    if ($result.ObjectType -eq "ServicePrincipal" -and $uniquePrincipalIds.ContainsKey($result.ObjectId)) {
                        $localScopesCovered[$result.Scope] = $true
                        $roleAssignmentsById[$result.RoleAssignmentId] = $result
                        $roleAssignmentsCount++
                    }
                }
                foreach ($localScope in $localScopesCovered.Keys) {
                    $scopesCovered[$localScope] = $true
                }
            }
        }
        # management groups (we are not trying to optimize based on the management group tree structure)
        foreach ($scope in $uniqueRoleAssignmentScopes.managementGroups.Keys) {
            if (!$scopesCovered.ContainsKey($scope)) {
                $scopesCovered[$scope] = $true
                $results = @()
                Write-Information "    $scope"
                $results += Get-AzRoleAssignment -Scope $scope -WarningAction SilentlyContinue
                $scopesCollectedCount++
                $localScopesCovered = @{}
                foreach ($result in $results) {
                    if ($result.ObjectType -eq "ServicePrincipal" -and $uniquePrincipalIds.ContainsKey($result.ObjectId)) {
                        $localScopesCovered[$result.Scope] = $true
                        $roleAssignmentsById[$result.RoleAssignmentId] = $result
                        $roleAssignmentsCount++
                    }
                }
                foreach ($localScope in $localScopesCovered.Keys) {
                    $scopesCovered[$localScope] = $true
                }
            }
        }

        # loop through the collected role assignments to collate by principalId
        $deployedRoleAssignmentsByPrincipalId = $deployed.roleAssignmentsByPrincipalId
        foreach ($roleAssignment in $roleAssignmentsById.Values) {
            $principalId = $roleAssignment.ObjectId
            $normalizedRoleAssignment = @{
                id               = $roleAssignment.RoleAssignmentId
                scope            = $roleAssignment.Scope
                displayName      = $roleAssignment.DisplayName
                objectType       = $roleAssignment.ObjectType
                principalId      = $principalId
                roleDefinitionId = $roleAssignment.RoleDefinitionId
                roleDisplayName  = $roleAssignment.RoleDefinitionName
            }
            if ($deployedRoleAssignmentsByPrincipalId.ContainsKey($principalId)) {
                $normalizedRoleAssignments = $deployedRoleAssignmentsByPrincipalId.$principalId
                $normalizedRoleAssignments += $normalizedRoleAssignment
                $deployedRoleAssignmentsByPrincipalId[$principalId] = $normalizedRoleAssignments
            }
            else {
                $null = $deployedRoleAssignmentsByPrincipalId.Add($principalId, @( $normalizedRoleAssignment ))
            }
        }
        Write-Information ""
        Write-Information "Role Assignments:"
        Write-Information "    Total principalIds     = $($deployedRoleAssignmentsByPrincipalId.Count)"
        Write-Information "    Total Role Assignments = $($roleAssignmentsById.Count)"
        Write-Information "    Total Scopes           = $($scopesCovered.Count)"
    }

    # Collect Exemptions
    if (!$skipExemptions) {
        $exemptionsProcessed = @{}
        $exemptionsTable = $deployed.policyExemptions
        $managedByCounters = $exemptionsTable.counters.managedBy
        $managedPolicyAssignmentsTable = $policyAssignmentsTable.managed
        $excludedPolicyAssignmentsTable = $policyAssignmentsTable.excluded
        $orphanedResourceTable = @{
            all      = @{}
            managed  = @{}
            excluded = @{}
            orphaned = @{}
            counters = @{
                managedBy = @{
                    thisPaC  = 0
                    otherPaC = 0
                    unknown  = 0
                }
            }
        }

        foreach ($scopeId in $scopeTable.Keys) {
            $scopeInformation = $scopeTable.$scopeId
            if ($scopeInformation.type -eq "microsoft.resources/subscriptions") {
                Get-AzPolicyExemption -Scope $scopeId -IncludeDescendent | Sort-Object Properties.PolicyAssignmentId, ResourceId |  ForEach-Object {
                    $properties = $_.Properties
                    $id = $_.ResourceId
                    if (!$exemptionsProcessed.ContainsKey($id)) {
                        # Filter out duplicates in parent Management Groups
                        $null = $exemptionsProcessed.Add($id, $_)

                        # normalize values to az cli representation
                        $description = $properties.Description
                        $displayName = $properties.DisplayName
                        $exemptionCategory = $properties.ExemptionCategory
                        $expiresOn = $properties.ExpiresOn
                        $metadata = $properties.Metadata
                        $name = $_.Name
                        $policyAssignmentId = $properties.PolicyAssignmentId
                        $policyDefinitionReferenceIds = $properties.PolicyDefinitionReferenceIds
                        $resourceGroup = $_.ResourceGroupName

                        # Find scope
                        $resourceIdParts = Split-AzPolicyResourceId -id $id
                        $scope = $resourceIdParts.scope

                        $exemption = @{
                            id                 = $id
                            name               = $name
                            scope              = $scope
                            policyAssignmentId = $policyAssignmentId
                            exemptionCategory  = $exemptionCategory
                        }
                        if ($null -ne $displayName -and $displayName -ne "") {
                            $null = $exemption.Add("displayName", $displayName)
                        }
                        if ($null -ne $description -and $description -ne "") {
                            $null = $exemption.Add("description", $description)
                        }
                        if ($null -ne $expiresOn) {
                            $expiresOnUtc = $expiresOn.ToUniversalTime()
                            $null = $exemption.Add("expiresOn", $expiresOnUtc)
                        }
                        if ($null -ne $policyDefinitionReferenceIds -and $policyDefinitionReferenceIds.Count -gt 0) {
                            $null = $exemption.Add("policyDefinitionReferenceIds", $policyDefinitionReferenceIds)
                        }
                        if ($null -ne $metadata -and $metadata -ne @{} ) {
                            $null = $exemption.Add("metadata", $metadata)
                        }
                        if ($null -ne $resourceGroup -and $resourceGroup -ne "") {
                            $null = $exemption.Add("resourceGroup", $resourceGroup)
                        }

                        # What is the context of this exemption; it depends on the assignment being exempted
                        if ($managedPolicyAssignmentsTable.ContainsKey($policyAssignmentId)) {
                            $policyAssignment = $managedPolicyAssignmentsTable.$policyAssignmentId
                            $pacOwner = $policyAssignment.pacOwner
                            $exemption.pacOwner = $pacOwner
                            if ($pacOwner -eq "thisPaC") {
                                $managedByCounters.thisPaC += 1
                            }
                            elseif ($pacOwner -eq "otherPaC") {
                                $managedByCounters.otherPaC += 1
                            }
                            else {
                                $managedByCounters.unknown += 1
                            }
                            $null = $exemptionsTable.managed.Add($id, $exemption)
                            $null = $exemptionsTable.all.Add($id, $exemption)
                        }
                        elseif ($excludedPolicyAssignmentsTable.ContainsKey($policyAssignmentId)) {
                            $policyAssignment = $excludedPolicyAssignmentsTable.$policyAssignmentId
                            if ($collectAllPolicies) {
                                $pacOwner = $policyAssignment.pacOwner
                                $exemption.pacOwner = $pacOwner
                                if ($pacOwner -eq "thisPaC") {
                                    $managedByCounters.thisPaC += 1
                                }
                                elseif ($pacOwner -eq "otherPaC") {
                                    $managedByCounters.otherPaC += 1
                                }
                                else {
                                    $managedByCounters.unknown += 1
                                }
                            }
                            $null = $exemptionsTable.excluded.Add($id, $exemption)
                            $null = $exemptionsTable.all.Add($id, $exemption)
                        }
                        else {
                            $included, $resourceIdParts = Confirm-PolicyResourceExclusions `
                                -testId $policyAssignmentId `
                                -resourceId $id `
                                -policyResource $exemption `
                                -scopeTable $scopeTable `
                                -includeResourceGroups $includeResourceGroups `
                                -excludedScopes $excludedScopes `
                                -excludedIds $excludedPolicyAssignments `
                                -policyResourceTable $orphanedResourceTable

                            # orphaned, do not differentiate
                            if ($included) {
                                $null = $exemptionsTable.orphaned.Add($id, $exemption)
                            }
                        }
                    }
                }
            }
        }
        $counters = $exemptionsTable.counters
        $managedBy = $counters.managedBy
        $managedByAny = $managedBy.thisPaC + $managedBy.otherPaC + $managedBy.unknown
        Write-Information ""
        Write-Information "Policy Exemptions:"
        Write-Information "    Managed ($($managedByAny)) by:"
        Write-Information "        This PaC    = $($managedBy.thisPaC)"
        Write-Information "        Other PaC   = $($managedBy.otherPaC)"
        Write-Information "        Unknown     = $($managedBy.unknown)"
        Write-Information "    Orphaned   = $($exemptionsTable.orphaned.Count)"
    }

    return $deployed
}
