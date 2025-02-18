#Requires -PSEdition Core

function Convert-PolicySetsToDetails {
    [CmdletBinding()]
    param (
        [hashtable] $allPolicyDefinitions,
        [hashtable] $allPolicySetDefinitions
    )

    $policyDetails = @{}
    Write-Information "Calculating effect parameters for $($allPolicyDefinitions.Count) Policy definitions."
    foreach ($policyId in $allPolicyDefinitions.Keys) {
        $policy = $allPolicyDefinitions.$policyId
        $properties = Get-PolicyResourceProperties -policyResource $policy
        $category = "Unknown"
        if ($properties.metadata -and $properties.metadata.category) {
            $category = $properties.metadata.category
        }
        $effectRawValue = $properties.policyRule.then.effect
        $found, $effectParameterName = Get-ParameterNameFromValueString -paramValue $effectRawValue

        $effectValue = $null
        $effectDefault = $null
        $effectAllowedValues = @()
        $effectReason = "Policy No Default"
        $parameters = $properties.parameters | ConvertTo-HashTable
        if ($found) {
            if ($effectParameter.allowedValues) {
                $effectAllowedValues = $effectParameter.allowedValues
            }
            if ($parameters.ContainsKey($effectParameterName)) {
                $effectParameter = $parameters.$effectParameterName
                if ($effectParameter.defaultValue) {
                    $effectValue = $effectParameter.defaultValue
                    $effectDefault = $effectParameter.defaultValue
                    $effectAllowedValues = @( $effectDefault )
                    $effectReason = "Policy Default"
                }
            }
            else {
                Write-Error "Policy uses parameter '$effectParameterName' for the effect not defined in the parameters. This should not be possible!" -ErrorAction Stop
            }
        }
        else {
            # Fixed value
            $effectValue = $effectRawValue
            $effectDefault = $effectRawValue
            $effectAllowedValues = @( $effectRawValue )
            $effectReason = "Policy Fixed"
        }

        $displayName = $properties.displayName
        if (-not $displayName -or $displayName -eq "") {
            $displayName = $policy.name
        }

        $description = $properties.description
        if (-not $description) {
            $description = ""
        }

        $parameterDefinitions = @{}
        foreach ($parameterName in $parameters.Keys) {
            $parameter = $parameters.$parameterName
            $parameterDefinition = @{
                isEffect     = $parameterName -eq $effectParameterName
                value        = $null
                defaultValue = $parameter.defaultValue
                definition   = $parameter
            }
            $null = $parameterDefinitions.Add($parameterName, $parameterDefinition)
        }

        $policyDetail = @{
            id                  = $policyId
            name                = $policy.name
            displayName         = $displayName
            description         = $description
            policyType          = $properties.policyType
            category            = $category
            effectParameterName = $effectParameterName
            effectValue         = $effectValue
            effectDefault       = $effectDefault
            effectAllowedValues = $effectAllowedValues
            effectReason        = $effectReason
            parameters          = $parameterDefinitions
        }
        $null = $policyDetails.Add($policyId, $policyDetail)
    }

    Write-Information "Calculating effect parameters for $($allPolicySetDefinitions.Count) Policy Set (Initiative) definitions."
    $policySetDetails = @{}
    foreach ($policySetId in $allPolicySetDefinitions.Keys) {
        $policySet = $allPolicySetDefinitions.$policySetId
        $properties = Get-PolicyResourceProperties -policyResource $policySet
        $category = "Unknown"
        if ($properties.metadata -and $properties.metadata.category) {
            $category = $properties.metadata.category
        }

        [System.Collections.ArrayList] $policyInPolicySetDetailList = [System.Collections.ArrayList]::new()
        $policySetParameters = Get-DeepClone $properties.parameters -AsHashTable
        $parametersAlreadyCovered = @{}
        foreach ($policyInPolicySet in $properties.policyDefinitions) {
            $policyId = $policyInPolicySet.policyDefinitionId
            if ($policyDetails.ContainsKey($policyId)) {
                $policyDetail = $policyDetails.$policyId
                $policyInPolicySetParameters = $policyInPolicySet.parameters | ConvertTo-HashTable

                $policySetLevelEffectParameterName = $null
                $effectParameterName = $policyDetail.effectParameterName
                $effectValue = $policyDetail.effectValue
                $effectDefault = $policyDetail.effectDefault
                $effectAllowedValues = $policyDetail.effectAllowedValues
                $effectReason = $policyDetail.effectReason

                $policySetLevelEffectParameterFound = $false
                $policySetLevelEffectParameterName = ""
                if ($effectReason -ne "Policy Fixed") {
                    # Effect is parameterized in Policy
                    if ($policyInPolicySetParameters.ContainsKey($effectParameterName)) {
                        # Effect parameter is used by policySet
                        $policySetLevelEffectParameter = $policyInPolicySetParameters.$effectParameterName
                        $effectRawValue = $policySetLevelEffectParameter.value

                        $policySetLevelEffectParameterFound, $policySetLevelEffectParameterName = Get-ParameterNameFromValueString -paramValue $effectRawValue
                        if ($policySetLevelEffectParameterFound) {
                            # Effect parameter is surfaced by PolicySet
                            if ($policySetParameters.ContainsKey($policySetLevelEffectParameterName)) {
                                $effectParameter = $policySetParameters.$policySetLevelEffectParameterName
                                if ($effectParameter.defaultValue) {
                                    $effectValue = $effectParameter.defaultValue
                                    $effectDefault = $effectParameter.defaultValue
                                    $effectReason = "PolicySet Default"
                                }
                                else {
                                    $effectReason = "PolicySet No Default"
                                }
                                if ($effectParameter.allowedValues) {
                                    $effectAllowedValues = $effectParameter.allowedValues
                                }
                            }
                            else {
                                Write-Error "Policy uses parameter '$effectParameterName' for the effect not defined in the parameters. This should not be possible!" -ErrorAction Stop
                            }
                        }
                        else {
                            # Effect parameter is hard-coded (fixed) by PolicySet
                            $policySetLevelEffectParameterName = $null
                            $effectValue = $effectRawValue
                            $effectDefault = $effectRawValue
                            $effectReason = "PolicySet Fixed"
                        }
                    }
                }

                # Process Policy parameters surfaced by PolicySet
                $surfacedParameters = @{}
                foreach ($parameterName in $policyInPolicySetParameters.Keys) {
                    $parameter = $policyInPolicySetParameters.$parameterName
                    $rawValue = $parameter.value
                    if ($rawValue -is [string]) {
                        $found, $policySetParameterName = Get-ParameterNameFromValueString -paramValue $rawValue
                        if ($found) {
                            $policySetParameter = $policySetParameters.$policySetParameterName
                            $multiUse = $false
                            $defaultValue = $policySetParameter.defaultValue
                            $isEffect = $policySetParameterName -eq $policySetLevelEffectParameterName
                            if ($parametersAlreadyCovered.ContainsKey($policySetParameterName)) {
                                $multiUse = $true
                            }
                            else {
                                $null = $parametersAlreadyCovered.Add($policySetParameterName, $true)
                            }
                            $null = $surfacedParameters.Add($policySetParameterName, @{
                                    multiUse     = $multiUse
                                    isEffect     = $isEffect
                                    value        = $defaultValue
                                    defaultValue = $defaultValue
                                    definition   = $policySetParameter
                                }
                            )
                        }
                    }
                }

                # Assemble the info
                $groupNames = @()
                if ($policyInPolicySet.groupNames) {
                    $groupNames = $policyInPolicySet.groupNames
                }
                $policyInPolicySetDetail = @{
                    id                          = $policyDetail.id
                    name                        = $policyDetail.name
                    displayName                 = $policyDetail.displayName
                    description                 = $policyDetail.description
                    policyType                  = $policyDetail.policyType
                    category                    = $policyDetail.category
                    effectParameterName         = $policySetLevelEffectParameterName
                    effectValue                 = $effectValue
                    effectDefault               = $effectDefault
                    effectAllowedValues         = $effectAllowedValues
                    effectReason                = $effectReason
                    parameters                  = $surfacedParameters
                    policyDefinitionReferenceId = $policyInPolicySet.policyDefinitionReferenceId
                    groupNames                  = $groupNames
                }
                $null = $policyInPolicySetDetailList.Add($policyInPolicySetDetail)
            }
            else {
                # This is a Policy of policyType static used for compliance purposes and not accessible to this code
                # SKIP
            }
        }

        # Assemble Policy Set info
        $displayName = $properties.displayName
        if (-not $displayName -or $displayName -eq "") {
            $displayName = $policySet.name
        }

        $description = $properties.description
        if (-not $description) {
            $description = ""
        }

        # Find Policy definitions appearing more than once in PolicySet
        $uniquePolicies = @{}
        $policiesWithMultipleReferenceIds = @{}
        foreach ($policyInPolicySetDetail in $policyInPolicySetDetailList) {
            $policyId = $policyInPolicySetDetail.id
            $policyDefinitionReferenceId = $policyInPolicySetDetail.policyDefinitionReferenceId
            if ($uniquePolicies.ContainsKey($policyId)) {
                if (-not $policiesWithMultipleReferenceIds.ContainsKey($policyId)) {
                    # First time detecting that this Policy has multiple references in the same PolicySet
                    $uniquePolicyReferenceIds = $uniquePolicies[$policyId]
                    $null = $policiesWithMultipleReferenceIds.Add($policyId, $uniquePolicyReferenceIds)
                }
                # Add current policyDefinitionReferenceId
                $multipleReferenceIds = $policiesWithMultipleReferenceIds[$policyId]
                $multipleReferenceIds += $policyDefinitionReferenceId
                $policiesWithMultipleReferenceIds[$policyId] = $multipleReferenceIds
            }
            else {
                # First time encounter in this PolicySet. Record Policy Id and remember policyDefinitionReferenceId
                $null = $uniquePolicies.Add($policyId, @( $policyDefinitionReferenceId ))
            }
        }

        $policySetDetail = @{
            id                               = $policySetId
            name                             = $policySet.name
            displayName                      = $displayName
            description                      = $description
            policyType                       = $properties.policyType
            category                         = $category
            parameters                       = $policySetParameters
            policyDefinitions                = $policyInPolicySetDetailList.ToArray()
            policiesWithMultipleReferenceIds = $policiesWithMultipleReferenceIds
        }
        $null = $policySetDetails.Add($policySetId, $policySetDetail)
    }

    # Assemble result
    $combinedPolicyDetails = @{
        policies   = $policyDetails
        policySets = $policySetDetails
    }

    return $combinedPolicyDetails
}