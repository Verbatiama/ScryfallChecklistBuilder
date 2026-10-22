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
        finishes         = @($card.finishes)
    }
}

function Get-SupabaseHeaders([string]$Key) {
    @{
        "apikey"        = $Key
        "Authorization" = "Bearer $Key"
        # PowerShell's default User-Agent starts with "Mozilla/5.0", which Supabase rejects as a browser for secret keys
        "User-Agent"    = "MTG_Checklist_Builder"
    }
}

# Read every row matching a PostgREST query, paging past the per-request row limit. The query needs an order for stable paging
function Get-SupabaseRows {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Key,
        [Parameter(Mandatory)] [string]$Table,
        [Parameter(Mandatory)] [string]$Query,
        [int]$PageSize = 1000
    )

    $endpoint = "$($Url.TrimEnd('/'))/rest/v1/$Table"
    $headers = Get-SupabaseHeaders $Key
    $offset = 0
    do {
        # Assign before wrapping: @(Invoke-RestMethod ...) would nest the response array as a single element
        $page = Invoke-RestMethod -Uri "$($endpoint)?$Query&limit=$PageSize&offset=$offset" -Headers $headers
        $page = @($page)
        $page
        $offset += $PageSize
    } while ($page.Count -eq $PageSize)
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

# Upsert changed rows and delete removed rows, using a local state file of row hashes (one section per table) to skip unchanged rows
function Sync-Supabase {
    param(
        [Parameter(Mandatory)] $Rows,
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Key,
        [string]$Table = "cards",
        [string]$KeyColumn = "id",
        [string]$StatePath = "$PSScriptRoot\.supabase_state.json",
        [int]$UpsertBatchSize = 500,
        [int]$DeleteBatchSize = 100
    )

    $allState = @{}
    if (Test-Path $StatePath) {
        (Get-Content $StatePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $allState[$_.Name] = $_.Value }
        # Older state files were a flat id -> hash map for a single table; move it under the table being synced
        if ($allState.Values | Where-Object { $_ -is [string] } | Select-Object -First 1) {
            $allState = @{ $Table = [pscustomobject]$allState }
        }
    }
    $state = @{}
    if ($allState[$Table]) {
        $allState[$Table].PSObject.Properties | ForEach-Object { $state[$_.Name] = $_.Value }
    }

    $endpoint = "$($Url.TrimEnd('/'))/rest/v1/$Table"
    $headers = Get-SupabaseHeaders $Key
    $headers["Prefer"] = "resolution=merge-duplicates,return=minimal"

    $currentIds = New-Object 'System.Collections.Generic.HashSet[string]'
    $changed = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $Rows) {
        $hash = Get-StringHash ($row | ConvertTo-Json -Depth 10 -Compress)
        $rowKey = [string]$row[$KeyColumn]
        [void]$currentIds.Add($rowKey)
        if ($state[$rowKey] -ne $hash) {
            $changed.Add([pscustomobject]@{ Key = $rowKey; Row = $row; Hash = $hash })
        }
    }
    $removed = @($state.Keys | Where-Object { -not $currentIds.Contains($_) })

    $upserted = 0
    $deleted = 0
    try {
        # Delete first so removed rows free up any unique values (e.g. binder positions) the upserts move into
        for ($i = 0; $i -lt $removed.Count; $i += $DeleteBatchSize) {
            $batch = $removed[$i..([Math]::Min($i + $DeleteBatchSize, $removed.Count) - 1)]
            Invoke-RestMethod -Method Delete -Uri "$($endpoint)?$KeyColumn=in.($($batch -join ','))" -Headers $headers | Out-Null
            foreach ($id in $batch) { $state.Remove($id) }
            $deleted += $batch.Count
        }

        for ($i = 0; $i -lt $changed.Count; $i += $UpsertBatchSize) {
            $batch = $changed.GetRange($i, [Math]::Min($UpsertBatchSize, $changed.Count - $i))
            $body = ConvertTo-Json -InputObject @($batch | ForEach-Object { $_.Row }) -Depth 10 -Compress
            Invoke-RestMethod -Method Post -Uri "$($endpoint)?on_conflict=$KeyColumn" -Headers $headers `
                -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
            foreach ($item in $batch) { $state[$item.Key] = $item.Hash }
            $upserted += $batch.Count
            Write-Verbose "Upserted $upserted / $($changed.Count) $Table rows"
        }
    }
    finally {
        # Save progress even on failure so the next run only retries what didn't go through
        $allState[$Table] = $state
        $allState | ConvertTo-Json -Depth 3 -Compress | Set-Content -Path $StatePath -Encoding UTF8
        Write-Verbose "Supabase sync ($Table): $upserted upserted, $deleted deleted, $($currentIds.Count - $changed.Count) unchanged"
    }
}
