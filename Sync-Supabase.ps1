# Windows PowerShell 5.1 serializes arrays as {"value":[...],"Count":n} unless this type data is removed
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Remove-TypeData System.Array -ErrorAction SilentlyContinue
}

# Parse KEY=VALUE lines from a .env file into a hashtable, ignoring blanks and # comments
function Import-DotEnv([string]$Path) {
    $vars = @{}
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*([^#=\s][^=]*?)\s*=\s*(.*?)\s*$') {
            $vars[$Matches[1]] = $Matches[2] -replace '^(["''])(.*)\1$', '$2'
        }
    }
    $vars
}

function ConvertTo-Price($value) {
    if ([string]::IsNullOrEmpty($value)) { return $null }
    [decimal]::Parse([string]$value, [System.Globalization.CultureInfo]::InvariantCulture)
}

# Build the database row for a Scryfall card object
function ConvertTo-DbRow($card) {
    # Double-faced cards have no top-level image_uris, so fall back to the front face
    $images = if ($card.image_uris) { $card.image_uris } elseif ($card.card_faces) { $card.card_faces[0].image_uris }
    [ordered]@{
        id               = $card.id
        name             = $card.name
        set_name         = $card.set_name
        regular_price    = ConvertTo-Price $card.prices.usd
        foil_price       = ConvertTo-Price $card.prices.usd_foil
        etched_price     = ConvertTo-Price $card.prices.usd_etched
        released_at      = $card.released_at
        collector_number = [int]$card.collector_number_value
        image_grid       = $images.grid
        image_display    = $images.display
        card_faces       = if ($card.card_faces) { @($card.card_faces) } else { $null }
    }
}

function Get-StringHash([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))) -replace '-', ''
    }
    finally {
        $sha.Dispose()
    }
}

# Upsert changed rows and delete removed rows, using a local state file of row hashes to skip unchanged rows
function Sync-Supabase {
    param(
        [Parameter(Mandatory)] $Rows,
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Key,
        [string]$Table = "cards",
        [string]$StatePath = "$PSScriptRoot\.supabase_state.json",
        [int]$UpsertBatchSize = 500,
        [int]$DeleteBatchSize = 100
    )

    $state = @{}
    if (Test-Path $StatePath) {
        (Get-Content $StatePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $state[$_.Name] = $_.Value }
    }

    $endpoint = "$($Url.TrimEnd('/'))/rest/v1/$Table"
    $headers = @{
        "apikey"        = $Key
        "Authorization" = "Bearer $Key"
        "Prefer"        = "resolution=merge-duplicates,return=minimal"
    }

    $currentIds = New-Object 'System.Collections.Generic.HashSet[string]'
    $changed = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $Rows) {
        $hash = Get-StringHash ($row | ConvertTo-Json -Depth 10 -Compress)
        [void]$currentIds.Add($row.id)
        if ($state[$row.id] -ne $hash) {
            $changed.Add([pscustomobject]@{ Row = $row; Hash = $hash })
        }
    }
    $removed = @($state.Keys | Where-Object { -not $currentIds.Contains($_) })

    $upserted = 0
    $deleted = 0
    try {
        for ($i = 0; $i -lt $changed.Count; $i += $UpsertBatchSize) {
            $batch = $changed.GetRange($i, [Math]::Min($UpsertBatchSize, $changed.Count - $i))
            $body = ConvertTo-Json -InputObject @($batch | ForEach-Object { $_.Row }) -Depth 10 -Compress
            Invoke-RestMethod -Method Post -Uri "$($endpoint)?on_conflict=id" -Headers $headers `
                -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
            foreach ($item in $batch) { $state[$item.Row.id] = $item.Hash }
            $upserted += $batch.Count
            Write-Verbose "Upserted $upserted / $($changed.Count) rows"
        }

        for ($i = 0; $i -lt $removed.Count; $i += $DeleteBatchSize) {
            $batch = $removed[$i..([Math]::Min($i + $DeleteBatchSize, $removed.Count) - 1)]
            Invoke-RestMethod -Method Delete -Uri "$($endpoint)?id=in.($($batch -join ','))" -Headers $headers | Out-Null
            foreach ($id in $batch) { $state.Remove($id) }
            $deleted += $batch.Count
        }
    }
    finally {
        # Save progress even on failure so the next run only retries what didn't go through
        $state | ConvertTo-Json -Depth 2 -Compress | Set-Content -Path $StatePath -Encoding UTF8
        Write-Verbose "Supabase sync: $upserted upserted, $deleted deleted, $($currentIds.Count - $changed.Count) unchanged"
    }
}
