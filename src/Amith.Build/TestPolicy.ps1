function Get-AmithTestPolicy {
    param($Plan)
    $options=Get-AmithValue $Plan 'TestPolicy' @{}
    $noTests=ConvertTo-AmithBoolean (Get-AmithValue $options 'NoTests' $false)
    $skipTests=ConvertTo-AmithBoolean (Get-AmithValue $options 'SkipTests' $false)
    if ($noTests -and $skipTests) { throw 'NoTests and SkipTests are mutually exclusive. Declare no test projects, or explicitly skip execution.' }
    return @{NoTests=$noTests;SkipTests=$skipTests}
}

function Assert-AmithNoTestsDeclaration {
    param($Projects,$Policy)
    if ($Policy.NoTests -and @($Projects | Where-Object Kind -eq 'Test').Count) {
        throw 'NoTests was declared, but the selected plan contains test projects. Remove NoTests to run them, or use SkipTests to explicitly bypass execution.'
    }
}

function Assert-AmithReleaseTestPolicy {
    param($Plan)
    $policy=Get-AmithTestPolicy $Plan
    $results=Get-AmithValue $Plan 'TestResults' @{}
    $disposition=Get-AmithValue $results 'Disposition' 'Executed'
    if ($policy.NoTests -or $policy.SkipTests) {
        Assert-AmithNoTestsDeclaration $Plan.Projects $policy
        $expected=if ($policy.NoTests) {'NoTests'} else {'Skipped'}
        if ($disposition -ne $expected) { throw 'Run the Test stage with the saved test policy before releasing. The intentional test bypass has not been recorded.' }
        Write-Warning "Release is proceeding with the explicitly recorded test policy: $expected."
    } elseif ((Get-AmithValue $results 'ExecutedTargets' 0) -lt 1 -or $disposition -ne 'Executed') {
        throw 'Release requires at least one executed test target. Run Test successfully, declare NoTests for a test-free plan, or explicitly use SkipTests when creating a new plan.'
    }
}
