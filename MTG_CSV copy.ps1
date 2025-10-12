
Get-Content -path "rawCards.json" | 
ConvertFrom-Json | 
Where-Object { 
    $_.set_name -eq "Unfinity Sticker Sheets"
} | 
# Output to JSON and pass data to the next step
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
} 

