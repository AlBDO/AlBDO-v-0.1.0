$dir = 'B:\albedo-pre-release\target\release'
$cur = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($cur -notlike "*$dir*") {
    $new = $cur + ';' + $dir
    [Environment]::SetEnvironmentVariable('PATH', $new, 'User')
    Write-Host "Added to user PATH: $dir"
} else {
    Write-Host "Already in PATH: $dir"
}
