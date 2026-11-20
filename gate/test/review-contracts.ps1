#requires -Version 5.1
# Точка входа -Extra штатного раннера. Имена всех проверок должны попадать под его фильтр.
foreach ($file in @('revision-contract.tests.ps1', 'recovery-contract.tests.ps1', 'evidence-contract.tests.ps1')) {
    $suite = @(. (Join-Path $PSScriptRoot $file))
    if ($suite.Count -eq 0) { throw "В файле $file нет тестов" }
    foreach ($case in $suite) {
        if ($case.Name -notlike 'review-*' -or $case.Run -isnot [scriptblock]) { throw "Некорректное описание теста в $file" }
        $case
    }
}
