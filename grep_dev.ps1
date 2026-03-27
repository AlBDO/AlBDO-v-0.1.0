$results = Select-String -Path 'B:\albedo-pre-release\src\bin\albedo.rs' -Pattern 'warm|preload|cold|init_engine|ComponentProject::new|quickjs|engine'
$results | Select-Object -First 30 | ForEach-Object {
    Write-Host ($_.LineNumber.ToString() + ': ' + $_.Line.Trim())
}
