function Remove-DuplicateByName {
    begin {
        $seenNames = @()
    }

    process {
        if ($seenNames -notcontains $_.Name) {
            $seenNames += $_.Name
            $_
        }
    }

    end {}
}
$firstRecord = $true
$regex = '^(?=.*\blegendary\b)(?=.*\bcreature\b).*$'
Get-Content -path "*.json" -Exclude "result.json" | 
ConvertFrom-Json | 
Where-Object { $_.type_line -match $regex -and `
        $_.reprint -ne "True" -and `
        $_.oversized -ne "True" -and `
        $_.variation -ne "True" -and `
        $_.games -match "paper" -and `
        $_.collector_number -notmatch "★|T|b" -and `
        $_.set_name -notmatch ".*\b(tokens|promos|Heroes of the Realm)\b.*" -and `
    ( $_.legalities.vintage -eq "legal" -or ($_.set_type -eq "funny" -and ($_.set_name -ne "Unknown Event" -and $_.set_name -like "Un*"))) 
} | 
ForEach-Object {
    $number = ($_.collector_number -replace '[^\d]', '')
    $_ | Add-Member -NotePropertyName 'collector_number_value' -NotePropertyValue ([int]($number)) -PassThru
} |
ForEach-Object -Begin {
    Remove-Item ".\result.json"
    "[" | Out-File -Append "result.json" 
} -Process {
    if (-not $firstRecord) {
        "," | Out-File -Append "result.json"
    }
    else {
        $firstRecord = $false
    }
    $_ | ConvertTo-Json -Depth 5 | Out-File -Append "result.json"
    $_
} -End { 
    "]" |  Out-File -Append "result.json" 
} |
Sort-Object -Property @{Expression = "released_at"; Descending = $false }, @{Expression = "set_name"; Descending = $false }, @{Expression = { [int]$_.collector_number_value }; Descending = $false } |
Select-Object -Property name, set_name, { $_.prices.usd }, { $_.prices.usd_foil }, released_at, collector_number | 
Remove-DuplicateByName |
Export-CSV "result.csv"
