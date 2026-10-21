[CmdletBinding()]
param()

# Only show progress bars (including Invoke-WebRequest's) when run with -Verbose
if ($VerbosePreference -eq 'SilentlyContinue') {
    $ProgressPreference = 'SilentlyContinue'
}

if (!(Test-Path "rawCards.jsonl.gz") -or ((Get-Date) - (Get-Item "rawCards.jsonl.gz").LastWriteTime).TotalDays -gt 1) {
    Write-Verbose "Downloading bulk data"
    $bulkDataLocations = Invoke-RestMethod -Uri "https://api.scryfall.com/bulk-data" -Headers @{"Accept" = "*/*"; "User-Agent" = "MTG_Checklist_Builder" }
    $downloadUri = ($bulkDataLocations.data | Where-Object { $_.type -eq "default_cards" }).jsonl_download_uri
    Invoke-WebRequest -Uri $downloadUri -OutFile "rawCards.jsonl.gz"
}
else{
    Write-Verbose "Using cached bulk data (rawCards.jsonl.gz)"
}

. "$PSScriptRoot\Sync-Supabase.ps1"
$dbRows = New-Object 'System.Collections.Generic.List[object]'

$regex = '^(?=.*\blegendary\b)(?=.*\bcreature\b).*$'

Write-Verbose "Filtering cards"
& {
    $gzipStream = New-Object System.IO.Compression.GZipStream([System.IO.File]::OpenRead("$PWD\rawCards.jsonl.gz"), [System.IO.Compression.CompressionMode]::Decompress)
    $reader = New-Object System.IO.StreamReader($gzipStream)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line) { $line }
        }
    }
    finally {
        $reader.Dispose()
    }
} |
ConvertFrom-Json | 
Where-Object { $_.type_line -match $regex -and `
        $_.reprint -ne "True" -and `
        $_.oversized -ne "True" -and `
        $_.variation -ne "True" -and `
        $_.games -match "paper" -and `
        $_.collector_number -notmatch "★|T|b" -and `
        $_.set_name -notmatch ".*\b(tokens|promos|Heroes of the Realm)\b.*" -and `
    ( $_.legalities.vintage -eq "legal" -or ($_.set -eq "fra" -or $_.set -eq "frc") -or ($_.set_type -eq "funny" -and ($_.set_name -ne "Unknown Event" -and $_.set_name -like "Un*"))) 
} | 
# Add collector_number_value as an integer property for sorting
ForEach-Object {
    $number = ($_.collector_number -replace '[^\d]', '')
    $_ | Add-Member -NotePropertyName 'collector_number_value' -NotePropertyValue ([int]($number)) -PassThru
} |
Sort-Object -Property @{Expression = "released_at"; Descending = $false }, @{Expression = "set_name"; Descending = $false }, @{Expression = { [int]$_.collector_number_value }; Descending = $false } |
# Output to JSON and pass data to the next step
ForEach-Object -Begin {
    $firstRecord = $true
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
    $dbRows.Add((ConvertTo-DbRow $_))
    $_
} -End { 
    "]" |  Out-File -Append "result.json" 
} |
# Remove duplicates based on the name property
ForEach-Object -Begin {
    $seenNames = @()
} -Process {
    if ($seenNames -notcontains $_.Name) {
        $seenNames += $_.Name
        $_
    }
} |
Select-Object -Property id, name, set_name, @{N = 'Regular Price'; E = { $_.prices.usd } }, @{N = 'Foil Price'; E = { $_.prices.usd_foil } }, released_at, @{N = 'collector_number'; E = { $_.collector_number_value } } |
ForEach-Object -Begin {
    $i = 0
} -Process {
    if (++$i % 100 -eq 0) {
        Write-Progress -Activity "Writing result.csv" -Status "$i cards"
    }
    $_
} -End {
    Write-Progress -Activity "Writing result.csv" -Completed
} |
Export-CSV "result.csv"

if (Test-Path "$PSScriptRoot\.env") {
    Write-Verbose "Updating db"
    $envVars = Import-DotEnv "$PSScriptRoot\.env"
    $table = if ($envVars.SUPABASE_TABLE) { $envVars.SUPABASE_TABLE } else { "cards" }
    Sync-Supabase -Rows $dbRows -Url $envVars.SUPABASE_URL -Key $envVars.SUPABASE_KEY -Table $table
}
else {
    Write-Warning ".env not found; skipping Supabase sync (copy .env.example to get started)"
}
