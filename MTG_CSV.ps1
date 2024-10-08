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


$regex = '^(?=.*\blegendary\b)(?=.*\bcreature\b).*$'
Get-Content "*.json" | 
ConvertFrom-Json | 
Where-Object { $_.type_line -match $regex  -and `
     $_.reprint -ne "True" -and `
     $_.oversized -ne "True" -and `
     $_.variation -ne "True"  -and `
     $_.games -match "paper" -and `
     $_.collector_number -notmatch "★|T|b" -and `
     $_.set_name -notmatch ".*\b(tokens|promos|Heroes of the Realm)\b.*"-and `
     ( $_.legalities.vintage -eq "legal" -or ($_.set_type -eq "funny" -and ($_.set_name -ne "Unknown Event" -and  $_.set_name -like "Un*")))} | 
ForEach-Object {
            $number = ($_.collector_number -replace '[^\d]', '')
            $_ | Add-Member -NotePropertyName 'collector_number_value' -NotePropertyValue ([int]($number)) -PassThru
        } |
Sort-Object -Property @{Expression = "released_at"; Descending = $false},@{Expression = "set_name"; Descending = $false}, @{Expression = {[int]$_.collector_number_value}; Descending = $false} |
Select-Object -Property name, set_name, {$_.prices.usd},{$_.prices.usd_foil}, released_at,  collector_number | 
Remove-DuplicateByName |
Export-CSV "result.csv"
