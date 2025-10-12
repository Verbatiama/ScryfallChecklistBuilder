
$data = Get-Content -path "result.json" | ConvertFrom-Json 


$data |
ForEach-Object -Begin {
    $seenNames = @()
} -Process {
    if ($seenNames -notcontains $_.tcgplayer_id) {
        $seenNames += $_.tcgplayer_id
        $_
    }
} |
ForEach-Object  -Process {
    $cardText = $_.oracle_text 
    $cardText -split "\n" |
    ForEach-Object {
        $result = @{ StickerCount = ""; Text = "" }
        $splitText = $_ -split "—"
        if ($splitText.Length -eq 2) {
            $result.StickerCount = $splitText[0].Split("{").Length
            $result.Text = $splitText[1].Trim()
            $result
        }
    }
} |
Export-Csv -Path "result.csv" -NoTypeInformation