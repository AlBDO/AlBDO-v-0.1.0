$results = Select-String -Path 'B:\albedo-pre-release\src\runtime\ast_eval.rs' -Pattern 'classnames|cx\b|npm|external|node_modules|resolve_import|eval_call_expr|ImportBinding|import_binding|call.*cx|cx.*call'
$results | Select-Object -First 40 | ForEach-Object {
    $ln = $_.LineNumber
    $line = $_.Line.Trim()
    Write-Host "$ln`: $line"
}
