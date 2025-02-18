#Requires -PSEdition Core

function Confirm-PolicySetDefinitionUsedExists {
    [CmdletBinding()]
    param(
        $id = $null,
        $name = $null,
        $policyDefinitionsScopes,

        [hashtable] $allPolicySetDefinitions
    )

    # Are the parameters correct?
    if (!($null -eq $id -xor $null -eq $name)) {
        Write-Error "Confirm-PolicySetDefinitionUsedExists called with a contradictory parameters: must supply either PolicySet id or PolicySet name." -ErrorAction Stop
    }

    # Find the PolicySet definition
    if ($null -ne $id) {
        if ($allPolicySetDefinitions.ContainsKey($id)) {
            return $id
        }
        else {
            Write-Error "    PolicySet (Initiative) '$id' not found."
            return $null
        }
    }
    else {
        foreach ($scopeId in $policyDefinitionsScopes) {
            $id = "$scopeId/providers/Microsoft.Authorization/policySetDefinitions/$name"
            if ($allPolicySetDefinitions.ContainsKey($id)) {
                return $id
            }
        }

        Write-Error "    PolicySet (Initiative) name '$name' not found in custom or built-in PolicySet (Initiative) definitions."
        return $null
    }
}
