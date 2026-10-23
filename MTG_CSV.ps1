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
$binderRows = New-Object 'System.Collections.Generic.List[object]'
$checklistCards = New-Object 'System.Collections.Generic.List[object]'

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
        $_.oversized -ne "True" -and `
        $_.variation -ne "True" -and `
        $_.games -match "paper" -and `
        $_.set_name -notmatch ".*\b(tokens|Heroes of the Realm)\b.*" -and `
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
Where-Object {
        $_.collector_number -notmatch "★|T|b" -and `
        $_.reprint -ne "True"
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
# Keep the full card objects for the collection repo's FullCards.json
ForEach-Object { $checklistCards.Add($_); $_ } |
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
# Assign each checklist row a binder position: 360 cards per book, 9 slots per page
ForEach-Object -Begin {
    $rowNumber = 0
} -Process {
    $binderRows.Add([ordered]@{
        card_id = $_.id
        book    = [int][Math]::Floor($rowNumber / 360) + 1
        page    = [int][Math]::Floor($rowNumber / 9) + 1
        slot    = ($rowNumber % 9) + 1
    })
    $rowNumber++
    $_
} |
Export-CSV "result.csv"

if (Test-Path "$PSScriptRoot\.env") {
    Write-Verbose "Updating db"
    $envVars = Import-DotEnv "$PSScriptRoot\.env"
    $table = if ($envVars.SUPABASE_TABLE) { $envVars.SUPABASE_TABLE } else { "cards" }
    Sync-Supabase -Rows $dbRows -Url $envVars.SUPABASE_URL -Key $envVars.SUPABASE_KEY -Table $table
    # Refuse to move a card that already has a binder position, since that would mean re-sleeving the binders by hand
    $savedPositions = @{}
    Get-SupabaseRows -Url $envVars.SUPABASE_URL -Key $envVars.SUPABASE_KEY -Table "binder_slots" `
        -Query "select=card_id,book,page,slot&order=card_id" | ForEach-Object { $savedPositions[$_.card_id] = $_ }
    $movedCount = 0
    for ($i = 0; $i -lt $binderRows.Count; $i++) {
        $row = $binderRows[$i]
        $saved = $savedPositions[$row.card_id]
        if ($saved -and ($saved.book -ne $row.book -or $saved.page -ne $row.page -or $saved.slot -ne $row.slot)) {
            Write-Host ("{0} would move from book {1} page {2} slot {3} to book {4} page {5} slot {6}" -f `
                $checklistCards[$i].name, $saved.book, $saved.page, $saved.slot, $row.book, $row.page, $row.slot) -ForegroundColor Red
            $movedCount++
        }
    }
    if ($movedCount -gt 0) {
        Write-Host "$movedCount binder positions would change; skipping binder_slots sync" -ForegroundColor Red
    }
    else {
        # binder_slots references cards, so it syncs after them. Positions shift together when a card is
        # added or removed, so send every change in one request to let the deferrable unique constraint pass
        Sync-Supabase -Rows $binderRows -Url $envVars.SUPABASE_URL -Key $envVars.SUPABASE_KEY -Table "binder_slots" `
            -KeyColumn "card_id" -UpsertBatchSize ([Math]::Max(1, $binderRows.Count))
    }

    # Write collection.json and FullCards.json into the collection repo, left uncommitted for manual review
    $repoPath = $envVars.COLLECTION_REPO_PATH
    if ($repoPath -and (Test-Path $repoPath)) {
        Write-Verbose "Exporting collection to $repoPath"
        # dbRows has every printing, for looking up the copy in a slot and its card's other printings
        $printings = @{}
        $printingsByName = @{}
        foreach ($row in $dbRows) {
            $printings[$row.id] = $row
            if (-not $printingsByName[$row.name]) { $printingsByName[$row.name] = New-Object 'System.Collections.Generic.List[object]' }
            $printingsByName[$row.name].Add($row)
        }
        $priceColumns = @{ nonfoil = "regular_price"; foil = "foil_price"; etched = "etched_price" }

        # A card counts as owned when any printing of it is
        $ownedNames = New-Object 'System.Collections.Generic.HashSet[string]'
        Get-SupabaseRows -Url $envVars.SUPABASE_URL -Key $envVars.SUPABASE_KEY -Table "card_ownership" `
            -Query "select=id&quantity=gt.0&order=id,foiling" | ForEach-Object { [void]$ownedNames.Add($printings[$_.id].name) }
        # The printing and foiling in each slot are edited in Supabase rather than set here, so read them back
        $slotCopies = @{}
        Get-SupabaseRows -Url $envVars.SUPABASE_URL -Key $envVars.SUPABASE_KEY -Table "binder_slots" `
            -Query "select=card_id,printing_id,foiling&order=card_id" | ForEach-Object { $slotCopies[$_.card_id] = $_ }

        # checklistCards and binderRows come from the same stream, so they line up by index
        $collection = for ($i = 0; $i -lt $checklistCards.Count; $i++) {
            $card = $checklistCards[$i]
            $slot = $binderRows[$i]
            $copy = $slotCopies[$card.id]
            $printingId = if ($copy.printing_id) { $copy.printing_id } else { $card.id }
            $foiling = if ($copy.foiling) { $copy.foiling } else { "nonfoil" }
            $printing = $printings[$printingId]
            # Price the copy in the slot at its foiling, then its other finishes. A printing with no prices at all
            # takes the cheapest of the card's other printings, at the same foiling if any have one
            $price = @($printing[$priceColumns[$foiling]], $printing.regular_price, $printing.foil_price, $printing.etched_price) |
                Where-Object { $null -ne $_ } | Select-Object -First 1
            if ($null -eq $price) {
                $others = $printingsByName[$card.name]
                $price = $others | ForEach-Object { $_[$priceColumns[$foiling]] } | Where-Object { $null -ne $_ } | Sort-Object | Select-Object -First 1
                if ($null -eq $price) {
                    $price = $others | ForEach-Object { $_.regular_price; $_.foil_price; $_.etched_price } | Where-Object { $null -ne $_ } |
                        Sort-Object | Select-Object -First 1
                }
            }
            [ordered]@{
                Id         = $printingId
                Name       = $card.name
                Owned      = [int]$ownedNames.Contains($card.name)
                Foiling    = $foiling
                Price      = if ($null -ne $price) { [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '${0:F2}', $price) } else { $null }
                "Set Name" = $card.set_name
                Book       = $slot.book
                Page       = $slot.page
                Slot       = $slot.slot
            }
        }
        $collectionJson = ConvertTo-Json -InputObject @($collection) -Depth 2
        [System.IO.File]::WriteAllText((Join-Path $repoPath "collection.json"), $collectionJson + [Environment]::NewLine)

        # Same layout as result.json: one pretty-printed object per card with "," lines between
        $fullCardLines = New-Object 'System.Collections.Generic.List[string]'
        $fullCardLines.Add("[")
        foreach ($card in $checklistCards) {
            if ($fullCardLines.Count -gt 1) { $fullCardLines.Add(",") }
            $fullCardLines.Add(($card | ConvertTo-Json -Depth 5))
        }
        $fullCardLines.Add("]")
        [System.IO.File]::WriteAllLines((Join-Path $repoPath "FullCards.json"), $fullCardLines)
        Write-Verbose "Exported $($checklistCards.Count) cards; review and commit the changes in $repoPath"
    }
    else {
        Write-Warning "COLLECTION_REPO_PATH not set in .env or not found; skipping collection export"
    }
}
else {
    Write-Warning ".env not found; skipping Supabase sync (copy .env.example to get started)"
}
