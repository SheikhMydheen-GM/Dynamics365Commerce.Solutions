[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Archive,

    [Parameter(Mandatory = $false)]
    [string[]]$LegacyHashAlgorithms,

    [Parameter(Mandatory = $false)]
    [switch]$SaveTransformedXml
)

Add-Type -AssemblyName System.IO
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.Security

#region Main

<#
.DESCRIPTION
    The main function.
#>
function main {
    param()

    try {
        Initialize-Labels

        if (-not $(Test-Path $Archive)) {
            Write-Host ($Labels.FileNotFound -f $Archive)
            return
        }

        $private:archiveItem = Get-Item $Archive
        $script:CertificatesLocation = $private:archiveItem.DirectoryName
        $private:reportBytes, $private:signatureBytes = Get-ReportAndSignatureBytes $private:archiveItem
        $private:reportStream = New-Object System.IO.MemoryStream $private:reportBytes, $false
        $private:xml = New-Object System.Xml.XmlDocument
        $private:xml.Load($private:reportStream)
        $private:archivePeriod = $private:xml.ArchivePeriod

        Validate-ArchiveFile `
            $private:reportBytes `
            $private:signatureBytes `
            $private:archivePeriod.PeriodGrandTotal.HashAlgorithm `
            $private:archivePeriod.PeriodGrandTotal.CertificateThumbprint

        $private:xml = Apply-Transformations $private:reportStream

        $private:nodes = $private:xml.SelectNodes("//*[
            self::PeriodGrandTotal or
            self::Shift or
            self::Receipt or
            self::ReceiptCopy or
            self::AuditEvent]"
        )

        $private:nodes | Validate-DataIntegrity -totalCount $private:nodes.Count
        Write-Host
    }
    catch {
        Write-Host $_ -ForegroundColor "Red"
        exit -1
    }
}

<#
.DESCRIPTION
    Gets byte arrays for the report file and the signature.
#>
function Get-ReportAndSignatureBytes {
    param (
        $archiveItem
    )
    try {
        $mode = [System.IO.FileMode]::Open
        $access = [System.IO.FileAccess]::Read
        $sharing = [IO.FileShare]::Read
        [System.IO.MemoryStream]$reportMemoryStream = New-Object System.IO.MemoryStream
        [Byte[]]$reportBytes = [System.Byte[]]::CreateInstance([System.Byte], 0)
        [Byte[]]$signatureBytes = [System.Byte[]]::CreateInstance([System.Byte], 0)

        if ($archiveItem.Extension -eq ".xml") {
            $reportFileStream = New-Object System.IO.FileStream $archiveItem.FullName, $mode, $access, $sharing
            $reportFileStream.CopyTo($reportMemoryStream)
            $reportBytes = $reportMemoryStream.ToArray()

            $signatureFilePath = Join-Path -Path $archiveItem.Directory "$($archiveItem.BaseName).sign"
            if (Test-Path $signatureFilePath) {
                $signatureFileStream = New-Object System.IO.FileStream $signatureFilePath, $mode, $access, $sharing
                $signatureStreamReader = New-Object System.IO.StreamReader $signatureFileStream
                $signatureText = $signatureStreamReader.ReadToEnd()
                $signatureBytes = [System.Text.Encoding]::ASCII.GetBytes($signatureText)
            }
            else {
                $reason = $Labels.SignatureFileNotFound -f $signatureFilePath
                Write-Warning ($Labels.UnableValidateArchive -f $reason)
            }
        }
        else {
            throw ($Labels.UnsupportedFileType -f $archiveItem)
        }

        @($reportBytes, $signatureBytes)
    }
    finally {
        if ($reportFileStream) { $reportFileStream.Close() }
        if ($signatureFileStream) { $signatureFileStream.Close() }
    }
}

<#
.DESCRIPTION
    Applies the required XSL transformations and returns the transformed XML document.
#>
function Apply-Transformations {
    param (
        [System.IO.Stream]$originalReportStream
    )

    try {
        Write-Progress -Activity $Labels.Initialization
        if ($originalReportStream.CanSeek) {
            $originalReportStream.Position = 0;
        }

        $originalReportStreamXmlReader = [System.Xml.XmlReader]::Create($originalReportStream)
        $transformedReportStream = New-Object System.IO.MemoryStream
        $transformedReportStreamXmlWriter = [System.Xml.XmlWriter]::Create($transformedReportStream)
        $xslInputElement = New-Object System.Xml.Xsl.XslCompiledTransform
        $xslInputElement.Load((Join-Path $PSScriptRoot "sort.xsl"))
        $xslInputElement.Transform($originalReportStreamXmlReader, $transformedReportStreamXmlWriter)
        $transformedReportStream.Position = 0
        $transformedXml = New-Object System.Xml.XmlDocument
        $transformedXml.Load($transformedReportStream)
        if ($SaveTransformedXml) {
            $transformedXmlFileName = [System.IO.Path]::Combine(
                [System.IO.Path]::GetDirectoryName($Archive),
                [System.IO.Path]::GetFileNameWithoutExtension($Archive) + "_transformed.xml")
            $transformedXml.Save($transformedXmlFileName)
            Write-Verbose $transformedXmlFileName
        }
        $transformedXml
    }
    finally {
        Write-Progress -Activity $Labels.Initialization -Completed
        if ($transformedReportStream) { $transformedReportStream.Close() };
    }
}

<#
.DESCRIPTION
    Validates the archive file.
#>
function Validate-ArchiveFile {
    param (
        [System.Byte[]]$reportBytes,
        [System.Byte[]]$signatureBytes,
        [string]$hashAlgorithm,
        [string]$thumbprint
    )
    Write-Verbose $Labels.ValidatingArchive
    try {
        if (-not $reportBytes.Length) {
            Write-Verbose $Labels.ReportEmpty
            return
        }
        if (-not $signatureBytes.Length) {
            Write-Verbose $Labels.SignatureFileEmpty
            return
        }
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$certificate = Find-X509Certificate $thumbprint
        if ($null -eq $certificate) {
            throw ($Labels.CertificateNotFound -f $thumbprint)
        }
        $signature = [System.Text.Encoding]::UTF8.GetString($signatureBytes)
        $valid = Verify-Data $reportBytes $signature $hashAlgorithm $thumbprint
        if ($valid) {
            Write-Host $Labels.ArchiveValidationPassed -ForegroundColor "Green"
        }
        else {
            Write-Host $Labels.ArchiveValidationFailed -ForegroundColor "Red"
        }
    }
    catch {
        Write-Warning ($Labels.UnableValidateArchive -f $_)
    }
}

<#
.DESCRIPTION
    Validates the data integrity of a node.
#>
function Validate-DataIntegrity {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline)]
        [System.Xml.XmlElement]$node,

        [Parameter()]
        [int]$totalCount
    )

    begin {
        $i = 0
        $percentComplete = 0
        $validCount = 0
        $activity = $Labels.ValidationActivity
    }

    process {
        $valid = $false
        try {
            $nodeName = $node.Name
            $idProperty = $node.Attributes.Item(0).Name
            $idValue = $node.Attributes.Item(0).Value
            $registerNumber = $node.RegisterNumber
            $nodeHeader = "$nodeName $idProperty=$idValue"
            if ($registerNumber) {
                $nodeHeader += ", RegisterNumber=$registerNumber"
            }

            Write-Verbose ($Labels.ValidatingNode -f $nodeHeader)
            $recalculatedDataToSign = Calculate-DataToSign $node
            $recalculatedDataToSignBytes = [System.Text.Encoding]::UTF8.GetBytes($recalculatedDataToSign)
            if ($recalculatedDataToSign -eq $node.DataToSign) {
                $hashAlgorithms = @($node.HashAlgorithm)
                $legacy = -not $node.DataToSignFormatVersion
                if ($legacy) {
                    $valid = $false
                    if (-not $hashAlgorithms -and $LegacyHashAlgorithms) {
                        $hashAlgorithms = $LegacyHashAlgorithms
                    }
                }

                foreach ($hashAlgorithm in $hashAlgorithms) {
                    $signature = ConvertFrom-LegacyBase64UrlString ($node.Signature)
                    $valid = Verify-Data `
                        $recalculatedDataToSignBytes `
                        $signature `
                        $hashAlgorithm `
                        $node.CertificateThumbprint
                    if ($valid) {
                        break
                    }
                }
            }
            if ($valid) {
                Write-Verbose ($Labels.NodeValidationPassed -f $nodeHeader)
            }
            else {
                if ($recalculatedDataToSign -eq $node.DataToSign) {
                    $reason = $Labels.SignatureInvalid
                }
                else {
                    $reason = $Labels.DataIntegrityViolated
                }
                Write-Host  ($Labels.NodeValidationFailed -f $nodeHeader, $reason) -ForegroundColor "Red"
                if ($recalculatedDataToSign -ne $node.DataToSign) {
                    $originalMetadata = ConvertTo-Metadata $node $node.DataToSign
                    $recalculatedMetadata = ConvertTo-Metadata $node $recalculatedDataToSign
                    $diffHashTables = Compare-HashTable -Expected $originalMetadata -Actual $recalculatedMetadata
                    if ($diffHashTables) {
                        Write-Host $Labels.SeeExpectedAndActual
                        $diffHashTables | `
                            ForEach-Object { [PSCustomObject]$_ } | `
                            Format-Table -Property $Labels.AttributeHeader, $Labels.ExpectedValueHeader, $Labels.ActualValueHeader | `
                            Out-String
                    }
                }
            }
        }
        catch {
            Write-Warning ($Labels.UnableToValidateNode -f $nodeHeader, $_)
        }
        finally {
            if ($valid) {
                $validCount++
            }
            $i++
            $percentComplete = [int]($i / $totalCount * 100)
            Write-Progress -Activity $activity -Status ($Labels.PercentComplete -f $percentComplete) -PercentComplete $percentComplete
        }
    }

    end {
        Write-Progress -Activity $activity -Completed
        $invalidCount = $totalCount - $validCount
        $percentIncorrect = if ($totalCount) { [int]($invalidCount / $totalCount * 100) } else { 0 }
        Write-Host ($Labels.ValidationCompleted -f $invalidCount, $totalCount, $percentIncorrect)
    }
}

#endregion

<#
.DESCRIPTION
    Searches for an X.509 certificate in the specified path with the given thumbprint.
#>
function Find-X509Certificate {
    param (
        [string]$thumbprint
    )

    if (-not $script:CertificatesCache) {
        [hashtable]$script:CertificatesCache = @{}
    }

    if ($script:CertificatesCache.ContainsKey($thumbprint)) {
        $script:CertificatesCache[$thumbprint]
        return
    }

    Write-Verbose ($Labels.SearchingCertificate -f $thumbprint, $script:CertificatesLocation)
    $certificateItems = Get-ChildItem -Path "$script:CertificatesLocation\*" -Include *.cer, *.crt, *.pem, *.pfx
    foreach ($certificateItem in $certificateItems) {
        $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certificateItem.FullName
        if ($certificate.Thumbprint -eq $thumbprint) {
            Write-Verbose ($Labels.CertificateFound -f $certificate.GetName())
            $script:CertificatesCache[$thumbprint] = $certificate
            $certificate
            break
        }
    }
}

<#
.DESCRIPTION
    Validates the data against the specified signature.
#>
function Verify-Data {
    param (
        [byte[]]$bytes,
        [string]$signature,
        [string]$hashAlgorithm,
        [string]$thumbprint
    )

    if (-not $hashAlgorithm -or -not $thumbprint) {
        throw $Labels.HashOrThumbprintMissing
    }

    $certificate = Find-X509Certificate $thumbprint
    if ($null -eq $certificate) {
        throw ($Labels.CertificateNotFound -f $thumbprint)
    }

    $signatureBytes = ConvertFrom-Base64UrlString $signature
    [System.Security.Cryptography.RSA]$rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($certificate)
    $rsaSignaturePadding = [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    $rsa.VerifyData($bytes, $signatureBytes, $hashAlgorithm.ToUpper(), $rsaSignaturePadding)
}

<#
.DESCRIPTION
    Converts the specified base64url string into a byte array.
#>
function ConvertFrom-Base64UrlString {
    param (
        [string]$base64url
    )
    $base64 = $base64url
    if ($base64url.Length % 4 -ne 0) {
        $numberOfPadingCharachers = 4 - ($base64url.Length % 4)
        $lengthWithPadding = $base64url.Length + $numberOfPadingCharachers
        $base64 = $base64url.PadRight($lengthWithPadding, '=')
    }
    $base64 = $base64.Replace('_', '/').Replace('-', '+')
    $bytes = [System.Convert]::FromBase64String($base64)
    $bytes
}

<#
.DESCRIPTION
    Converts a legacy base64Url string to a base64 string.
#>
function ConvertFrom-LegacyBase64UrlString {
    param (
        [string]$legacyBase64UrlString
    )

    if (-not $legacyBase64UrlString) {
        return $legacyBase64UrlString
    }

    if ($legacyBase64UrlString.Length -lt 2) {
        return $legacyBase64UrlString
    }

    [int] $numPadChars = [int][char]$legacyBase64UrlString[$legacyBase64UrlString.Length - 1] - [int][char]'0';

    if ($numPadChars -lt 0 -or $numPadChars -gt 10) {
        return $legacyBase64UrlString
    }

    $suffix = New-Object string('=', $numPadChars)

    $signature = $legacyBase64UrlString.Remove($legacyBase64UrlString.Length - 1);

    $signature = $signature + $suffix

    $signature
}

<#
.DESCRIPTION
    Compares two hash tables and produces an object containing properties that are different.
#>
function Compare-HashTable {
    param (
        [alias('Expected')][hashtable]$expectedTable,
        [alias('Actual')][hashtable]$actualTable
    )

    <# Ensures a string is no longer than the allowed max length. #>
    function FitString ([string]$string) {
        $maxLength = 30
        if ($string.Length -gt $maxLength) {
            $string.Substring(0, $maxLength / 2) + "..." + $string.Substring($string.Length - $maxLength / 2)
        }
        else {
            $string
        }
    }

    foreach ($key in $expectedTable.Keys) {
        $expected = FitString $expectedTable[$key]
        $actual = FitString $actualTable[$key]
        if ($expected -ne $actual) {
            @{ $Labels.AttributeHeader = $key; $Labels.ExpectedValueHeader = $expected; $Labels.ActualValueHeader = $actual }
        }
    }
}

<#
.DESCRIPTION
    Calculates the data to sign for a node.
#>
function Calculate-DataToSign {
    param (
        [System.Xml.XmlElement]$node
    )


    $invalidFormatMessage = ($Labels.DataToSignFormatVersionInvalid -f $node.DataToSignFormatVersion)

    switch ($node.Name) {
        "PeriodGrandTotal" {
            if (-not $node.DataToSignFormatVersion) {
                throw $Labels.DataToSignFormatVersionMissing
            }
            switch ($node.DataToSignFormatVersion) {
                "2.1_4.0" { Calculate-PeriodGrandTotalDataToSign-2140 $node }
                default { throw $invalidFormatMessage }
            }
        }

        "Shift" {
            switch ($node.DataToSignFormatVersion) {
                "2.1_4.0" { Calculate-ShiftDataToSign-2140 $node }
                "" { Calculate-ShiftDataToSign-Legacy $node }
                default { throw $invalidFormatMessage }
            }
        }

        "Receipt" {
            switch ($node.DataToSignFormatVersion) {
                "2.1_4.0" { Calculate-ReceiptDataToSign-2140 $node }
                "" { Calculate-ReceiptDataToSign-Legacy $node }
                default { throw $invalidFormatMessage }
            }
        }

        "ReceiptCopy" {
            switch ($node.DataToSignFormatVersion) {
                "2.1_4.0" { Calculate-ReceiptCopyDataToSign-2140 $node }
                "" { Calculate-ReceiptCopyDataToSign-Legacy $node }
                default { throw $invalidFormatMessage }
            }
        }

        "AuditEvent" {
            switch ($node.DataToSignFormatVersion) {
                "2.1_4.0" { Calculate-AuditEventDataToSign-2140 $node }
                "" { Calculate-AuditEventDataToSign-Legacy $node }
                default { throw $invalidFormatMessage }
            }
        }

        default {
            throw ($Labels.NonSupportedNode -f $node.Name)
        }
    }
}

<#
.DESCRIPTION
    Converts the specified data to sign to a metadata object
    based on the node type and the data to sign format version.
#>
function ConvertTo-Metadata {
    param (
        [System.Xml.XmlElement]$node,
        [string]$dataToSign
    )

    $invalidFormatMessage = ($Labels.DataToSignFormatVersionInvalid -f $node.DataToSignFormatVersion)

    switch ($node.Name) {
        "PeriodGrandTotal" {
            if (-not $node.DataToSignFormatVersion) {
                throw $Labels.DataToSignFormatVersionMissing
            }

            switch ($node.DataToSignFormatVersion) {
                "2.1_4.0" { ConvertTo-PeriodGrandTotalMetadata-2140 $dataToSign }
                default { throw $invalidFormatMessage }
            }
        }

        "Shift" {
            switch ($node.DataToSignFormatVersion) {
                "2.1_4.0" { ConvertTo-ShiftMetadata-2140 $dataToSign }
                "" { ConvertTo-ShiftMetadata-Legacy $dataToSign }
                default { throw $invalidFormatMessage }
            }
        }

        "Receipt" {
            switch ($node.DataToSignFormatVersion) {
                "2.1_4.0" { ConvertTo-ReceiptMetadata-2140 $dataToSign }
                "" { ConvertTo-ReceiptMetadata-Legacy $dataToSign }
                default { throw $invalidFormatMessage }
            }
        }

        "ReceiptCopy" {
            switch ($node.DataToSignFormatVersion) {
                "2.1_4.0" { ConvertTo-ReceiptCopyMetadata-2140 $dataToSign }
                "" { ConvertTo-ReceiptCopyMetadata-Legacy $dataToSign }
                default { throw $invalidFormatMessage }
            }
        }

        "AuditEvent" {
            switch ($node.DataToSignFormatVersion) {
                "2.1_4.0" { ConvertTo-AuditEventMetadata-2140 $dataToSign }
                "" { ConvertTo-AuditEventMetadata-Legacy $dataToSign }
                default { throw $invalidFormatMessage }
            }
        }

        default {
            throw ($Labels.NonSupportedNode -f $node.Name)
        }
    }
}

#region PeriodGrandTotal

<#
.DESCRIPTION
    Calculates the data to sign for the PeriodGrandTotal node.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function Calculate-PeriodGrandTotalDataToSign-2140 {
    param (
        [System.Xml.XmlElement]$periodGrandTotal
    )
    $metadata = ConvertTo-PeriodGrandTotalMetadata-2140 $periodGrandTotal.DataToSign
    $part1 = ConvertTo-PeriodGrandTotalTotalAmountsByTaxRateString-2140 $periodGrandTotal.SelectSingleNode('PeriodGrandTotalLines')
    $part2 = $periodGrandTotal.GrandTotal
    $part3 = $periodGrandTotal.PerpetualGrandTotalAbsoluteValue
    $part4 = $metadata.SignDateTime
    $part5 = [System.String]::Join("|", $periodGrandTotal.FromDate, $periodGrandTotal.ToDate)
    $part6 = $periodGrandTotal.SequentialNumber
    $part7 = $metadata.IsFirstSigned
    $part8 = $metadata.PreviousSignature
    $result = [System.String]::Join(",", $part1, $part2, $part3, $part4, $part5, $part6, $part7)
    if ($part8) {
        $result += "," + $part8
    }
    $result
}

<#
.DESCRIPTION
    Converts PeriodGrandTotalLine elements into the string representation of the total amounts by VAT rate breakdown.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function ConvertTo-PeriodGrandTotalTotalAmountsByTaxRateString-2140 {
    param (
        [System.Xml.XmlElement]$periodGrandTotalLines
    )
    if ($null -eq $periodGrandTotalLines -or $periodGrandTotalLines.ChildNodes.Count -eq 0) {
        "0:0"
        return
    }
    $items = $periodGrandTotalLines.ChildNodes | ForEach-Object { "$($_.TaxRate):$($_.TotalInclTax)" }
    $result = [System.String]::Join("|", $items)
    $result
}

<#
.DESCRIPTION
    Converts the DataToSign element of the PeriodGrandTotal node into a metadata object.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function ConvertTo-PeriodGrandTotalMetadata-2140 {
    param (
        [string]$dataToSign
    )
    $values = $dataToSign.Split(",")
    @{
        PeriodGrandTotalLines            = $values[0]
        GrandTotal                       = $values[1]
        PerpetualGrandTotalAbsoluteValue = $values[2]
        SignDateTime                     = $values[3]
        Period                           = $values[4]
        SequentialNumber                 = $values[5]
        IsFirstSigned                    = $values[6]
        PreviousSignature                = $values[7]
    }
}

#endregion

#region Shift

<#
.DESCRIPTION
    Calculates the data to sign for the Shift node.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function Calculate-ShiftDataToSign-2140 {
    param (
        [System.Xml.XmlElement]$shift
    )
    $metadata = ConvertTo-ShiftMetadata-2140 $shift.DataToSign
    $previousShift = $shift.PreviousSibling
    $perviousSignature = if ($previousShift) {
        $previousShift.Signature
    }
    else {
        $metadata.PreviousSignature
    }

    $part1 = ConvertTo-ShiftTotalAmountsByTaxRateString-2140 $shift.SelectSingleNode('ShiftLines')
    $part2 = $shift.GrandTotal
    $part3 = $shift.PerpetualGrandTotalAbsoluteValue
    $part4 = $shift.Date
    $part5 = $shift.Date.Substring(0, 8)
    $part6 = $shift.SequentialNumber
    $part7 = if ($shift.SequentialNumber -eq "1") { "Y" } else { "N" }
    $part8 = if ($part7 -eq "N") { $perviousSignature } else { "" }
    $result = [System.String]::Join(",", $part1, $part2, $part3, $part4, $part5, $part6, $part7, $part8)
    $result
}

<#
.DESCRIPTION
    Converts ShiftLine elements into the string representation of the total amounts by VAT rate breakdown.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function ConvertTo-ShiftTotalAmountsByTaxRateString-2140 {
    param (
        [System.Xml.XmlElement]$shiftLines
    )
    if ($null -eq $shiftLines -or $shiftLines.ChildNodes.Count -eq 0) {
        "0:0"
        return
    }
    $items = $shiftLines.ChildNodes | ForEach-Object { "$($_.TaxRate):$($_.TotalInclTax)" }
    $result = [System.String]::Join("|", $items)
    $result
}

<#
.DESCRIPTION
    Converts the DataToSign element of the Shift node into a metadata object.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function ConvertTo-ShiftMetadata-2140 {
    param (
        [string]$dataToSign
    )
    $values = $dataToSign.Split(",")
    @{
        ShiftLines                       = $values[0]
        GrandTotal                       = $values[1]
        PerpetualGrandTotalAbsoluteValue = $values[2]
        RegistrationTime                 = $values[3]
        Period                           = $values[4]
        SequentialNumber                 = $values[5]
        IsFirstSigned                    = $values[6]
        PreviousSignature                = $values[7]
    }
}

<#
.DESCRIPTION
    Calculates the data to sign for the Shift node.

.NOTES
    The old version of receipt copy.
#>
function Calculate-ShiftDataToSign-Legacy {
    param (
        [System.Xml.XmlElement]$shift
    )
    $metadata = ConvertTo-ShiftMetadata-Legacy $shift.DataToSign
    $previousShift = $shift.PreviousSibling
    $perviousSignature = if ($previousShift) {
        $previousShift.Signature
    }
    else {
        $metadata.PreviousSignature
    }

    $perviousSignature = if ($metadata.IsFirstSigned -eq "N") { $perviousSignature } else { "" }
    $result = [System.String]::Join(",", $metadata.ShiftData, $metadata.IsFirstSigned, $perviousSignature)
    $result
}

<#
.DESCRIPTION
    Converts the DataToSign element of the Shift node into a metadata object.

.NOTES
    The old version of receipt copy.
#>
function ConvertTo-ShiftMetadata-Legacy {
    param (
        [string]$dataToSign
    )

    $values = $dataToSign.Split(",")
    $shiftData = [string]::Join(",", ($values |  Select-Object -First ($values.Count - 2)))
    @{
        ShiftData         = $shiftData
        IsFirstSigned     = $values[$values.Count - 2]
        PreviousSignature = $values[$values.Count - 1]
    }
}

#endregion

#region Receipt

<#
.DESCRIPTION
    Calculates the data to sign for the Receipt node.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function Calculate-ReceiptDataToSign-2140 {
    param (
        [System.Xml.XmlElement]$receipt
    )
    $metadata = ConvertTo-ReceiptMetadata-2140 $receipt.DataToSign
    $previousReceipt = $receipt.PreviousSibling
    $perviousSignature = if ($previousReceipt) {
        $previousReceipt.Signature
    }
    else {
        $metadata.PreviousSignature
    }

    $part1 = ConvertTo-ReceiptTotalAmountsByTaxRateString-2140 $receipt.SelectSingleNode('FooterLines')
    $part2 = $receipt.Total.InclTax
    $part3 = $receipt.Date
    $part4 = $receipt.RegisterNumber
    $part5 = $receipt.SequentialNumber
    $part6 = $metadata.TransactionType
    $part7 = if ($receipt.SequentialNumber -eq "1") { "Y" } else { "N" }
    $part8 = if ($part7 -eq "N") { $perviousSignature } else { "" }
    $result = [System.String]::Join(",", $part1, $part2, $part3, $part4, $part5, $part6, $part7, $part8)
    $result
}

<#
.DESCRIPTION
    Converts ReceiptLine elements into the string representation of the total amounts by tax rate breakdown.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function ConvertTo-ReceiptTotalAmountsByTaxRateString-2140 {
    param (
        [System.Xml.XmlElement]$footerLines
    )
    if ($null -eq $footerLines -or $footerLines.ChildNodes.Count -eq 0) {
        "0:0"
        return
    }
    $items = $footerLines.ChildNodes | ForEach-Object { "$($_.TaxRate):$($_.TotalInclTax)" }
    $result = [System.String]::Join("|", $items)
    $result
}

<#
.DESCRIPTION
    Converts the DataToSign element of the Receipt node into a metadata object.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function ConvertTo-ReceiptMetadata-2140 {
    param (
        [string]$dataToSign
    )
    $values = $dataToSign.Split(",")
    @{
        TotalAmountsByTaxRate = $values[0]
        TotalAmount           = $values[1]
        RegistrationTime      = $values[2]
        RegisterNumber        = $values[3]
        SequentialNumber      = $values[4]
        TransactionType       = $values[5]
        IsFirstSigned         = $values[6]
        PreviousSignature     = $values[7]
    }
}

<#
.DESCRIPTION
    Calculates the data to sign for the Receipt node.

.NOTES
    The old version of receipt copy.
#>
function Calculate-ReceiptDataToSign-Legacy {
    param (
        [System.Xml.XmlElement]$receipt
    )
    $metadata = ConvertTo-ReceiptMetadata-Legacy $receipt.DataToSign
    $previousReceipt = $receipt.PreviousSibling
    $perviousSignature = if ($previousReceipt) {
        $previousReceipt.Signature
    }
    else {
        $metadata.PreviousSignature
    }

    $part1 = $metadata.TotalAmountsByTaxRate
    $part2 = $metadata.TotalAmount
    $part3 = $metadata.RegistrationTime
    $part4 = $metadata.RegisterNumber
    $part5 = $metadata.SequentialNumber
    $part6 = $metadata.TransactionType
    $part7 = $metadata.IsFirstSigned
    $part8 = if ($part7 -eq "N") { $perviousSignature } else { "" }
    $part9 = $metadata.LineCount
    $result = [System.String]::Join(",", $part1, $part2, $part3, $part4, $part5, $part6, $part7, $part8, $part9)
    $result
}

<#
.DESCRIPTION
    Converts the DataToSign element of the Receipt node into a metadata object.

.NOTES
    The old version of receipt copy.
#>
function ConvertTo-ReceiptMetadata-Legacy {
    param (
        [string]$dataToSign
    )
    $values = $dataToSign.Split(",")
    @{
        TotalAmountsByTaxRate = $values[0]
        TotalAmount           = $values[1]
        RegistrationTime      = $values[2]
        RegisterNumber        = $values[3]
        SequentialNumber      = $values[4]
        TransactionType       = $values[5]
        IsFirstSigned         = $values[6]
        PreviousSignature     = $values[7]
        LineCount             = $values[8]
    }
}

#endregion

#region ReceiptCopy

<#
.DESCRIPTION
    Calculates the data to sign for the ReceiptCopy node.

.NOTES
    The old version of receipt copy.
#>
function Calculate-ReceiptCopyDataToSign-Legacy {
    param (
        [System.Xml.XmlElement]$receiptCopy
    )
    $metadata = ConvertTo-ReceiptCopyMetadata-Legacy $receiptCopy.DataToSign
    $previousReceiptCopy = $receiptCopy.PreviousSibling
    $perviousSignature = if ($previousReceiptCopy) {
        $previousReceiptCopy.Signature
    }
    else {
        $metadata.PreviousSignature
    }
    $part1 = $metadata.ReceiptId
    $part2 = $metadata.TransactionType
    $part3 = $metadata.CopyNumber
    $part4 = $metadata.OperatorCode
    $part5 = $metadata.RegistrationTime
    $part6 = $metadata.SequentialNumber
    $part7 = $metadata.IsFirstSigned
    $part8 = if ($part7 -eq "N") { $perviousSignature } else { "" }
    $result = [System.String]::Join(",", $part1, $part2, $part3, $part4, $part5, $part6, $part7, $part8)
    $result
}

<#
.DESCRIPTION
    Converts the DataToSign element of the ReceiptCopy node into a metadata object.

.NOTES
    The old version of receipt copy.
#>
function ConvertTo-ReceiptCopyMetadata-Legacy {
    param (
        [string]$dataToSign
    )
    $values = $dataToSign.Split(",")
    @{
        ReceiptId         = $values[0]
        TransactionType   = $values[1]
        CopyNumber        = $values[2]
        OperatorCode      = $values[3]
        RegistrationTime  = $values[4]
        SequentialNumber  = $values[5]
        IsFirstSigned     = $values[6]
        PreviousSignature = $values[7]
    }
}

<#
.DESCRIPTION
    Calculates the data to sign for the ReceiptCopy node.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function Calculate-ReceiptCopyDataToSign-2140 {
    param (
        [System.Xml.XmlElement]$receiptCopy
    )
    $metadata = ConvertTo-ReceiptCopyMetadata-2140 $receiptCopy.DataToSign
    $previousReceiptCopy = $receiptCopy.PreviousSibling
    $perviousSignature = if ($previousReceiptCopy) {
        $previousReceiptCopy.Signature
    }
    else {
        $metadata.PreviousSignature
    }
    $part1 = $receiptCopy.RegisterNumber
    $part2 = $metadata.SequentialNumber
    $part3 = $metadata.TransactionType
    $part4 = $receiptCopy.CopyNumber
    $part5 = $receiptCopy.OperatorCode
    $part6 = $receiptCopy.Date
    $part7 = $metadata.RefRegisterNumber
    $part8 = $metadata.RefSequentialNumber
    $part9 = if ($receiptCopy.SequentialNumber -eq "1") { "Y" } else { "N" }
    $part10 = if ($part9 -eq "N") { $perviousSignature } else { "" }
    $result = [System.String]::Join(",", $part1, $part2, $part3, $part4, $part5, $part6, $part7, $part8, $part9, $part10)
    $result
}

<#
.DESCRIPTION
    Converts the DataToSign element of the ReceiptCopy node into a metadata object.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function ConvertTo-ReceiptCopyMetadata-2140 {
    param (
        [string]$dataToSign
    )
    $values = $dataToSign.Split(",")
    @{
        RegisterNumber      = $values[0]
        SequentialNumber    = $values[1]
        TransactionType     = $values[2]
        CopyNumber          = $values[3]
        OperatorCode        = $values[4]
        RegistrationTime    = $values[5]
        RefRegisterNumber   = $values[6]
        RefSequentialNumber = $values[7]
        IsFirstSigned       = $values[8]
        PreviousSignature   = $values[9]
    }
}

#endregion

#region AuditEvent

<#
.DESCRIPTION
    Converts the DataToSign element of the AuditEvent node into a metadata object.

.NOTES
    Old version of audit event
#>
function ConvertTo-AuditEventMetadata-Legacy {
    param (
        [string]$dataToSign
    )
    $values = $dataToSign.Split(",")
    @{
        SequentialNumber  = $values[0]
        Code              = $values[1]
        Message           = $values[2]
        RegistrationTime  = $values[3]
        OperatorCode      = $values[4]
        RegisterNumber    = $values[5]
        IsFirstSigned     = $values[6]
        PreviousSignature = $values[7]
    }
}

<#
.DESCRIPTION
    Calculates the data to sign for the AuditEvent node.

.NOTES
    The old version of audit event
#>
function Calculate-AuditEventDataToSign-Legacy {
    param (
        [System.Xml.XmlElement]$auditEvent
    )
    $previousAuditEvent = $auditEvent.PreviousSibling
    $metadata = ConvertTo-AuditEventMetadata-Legacy $auditEvent.DataToSign
    $perviousSignature = if ($previousAuditEvent) {
        $previousAuditEvent.Signature
    }
    else {
        $metadata.PreviousSignature
    }
    $part1 = $metadata.SequentialNumber
    $part2 = $metadata.Code
    $part3 = $metadata.Message
    $part4 = $metadata.RegistrationTime
    $part5 = $metadata.OperatorCode
    $part6 = $auditEvent.RegisterNumber
    $part7 = $metadata.IsFirstSigned
    $part8 = if ($part7 -eq "N") { $perviousSignature } else { "" }
    $result = [System.String]::Join(",", $part1, $part2, $part3, $part4, $part5, $part6, $part7, $part8)
    $result
}


<#
.DESCRIPTION
    Calculates the data to sign for the AuditEvent node.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function Calculate-AuditEventDataToSign-2140 {
    param (
        [System.Xml.XmlElement]$auditEvent
    )
    $previousAuditEvent = $auditEvent.PreviousSibling
    $metadata = ConvertTo-AuditEventMetadata-2140 $auditEvent.DataToSign
    $perviousSignature = if ($previousAuditEvent) {
        $previousAuditEvent.Signature
    }
    else {
        $metadata.PreviousSignature
    }
    $part1 = $auditEvent.SequentialNumber
    $part2 = $auditEvent.Code
    $part3 = $metadata.Message
    $part4 = $auditEvent.Date
    $part5 = $auditEvent.OperatorCode
    $part6 = $auditEvent.RegisterNumber
    $part7 = if ($auditEvent.SequentialNumber -eq "1") { "Y" } else { "N" }
    $part8 = if ($part7 -eq "N") { $perviousSignature } else { "" }
    $result = [System.String]::Join(",", $part1, $part2, $part3, $part4, $part5, $part6, $part7, $part8)
    $result
}

<#
.DESCRIPTION
    Converts the DataToSign element of the AuditEvent node into a metadata object.

.NOTES
    NF525 V2.1. Data dictionaries R13 and R19 V4.0.
#>
function ConvertTo-AuditEventMetadata-2140 {
    param (
        [string]$dataToSign
    )
    $values = $dataToSign.Split(",")
    @{
        SequentialNumber  = $values[0]
        Code              = $values[1]
        Message           = $values[2]
        RegistrationTime  = $values[3]
        OperatorCode      = $values[4]
        RegisterNumber    = $values[5]
        IsFirstSigned     = $values[6]
        PreviousSignature = $values[7]
    }
}

#endregion

#region Labels

<#
.DESCRIPTION
    Initializes the labels object from the resource file which corresponds to the current culture.
#>
function Initialize-Labels {
    $resourcesDirectoryName = "resources"
    $resourcesFileName = "resources.resjson"
    $defaultCultureName = "en-US"
    $script:Labels = @{}
    $currentCultureName = (Get-Culture).Name
    $labelsPath = [IO.Path]::Combine($PSScriptRoot, $resourcesDirectoryName, $currentCultureName, $resourcesFileName)
    if (-not (Test-Path $labelsPath)) {
        $labelsPath = [IO.Path]::Combine($PSScriptRoot, $resourcesDirectoryName, $defaultCultureName, $resourcesFileName)
    }
    $script:Labels = Get-Content $labelsPath | ConvertFrom-Json
}

#endregion

main

# SIG # Begin signature block
# MIIoLQYJKoZIhvcNAQcCoIIoHjCCKBoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCABOVBQ2DkwtaVM
# GF+OU3vn9wR+6WcWtlCISILalhkIAKCCDXYwggX0MIID3KADAgECAhMzAAADrzBA
# DkyjTQVBAAAAAAOvMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjMxMTE2MTkwOTAwWhcNMjQxMTE0MTkwOTAwWjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQDOS8s1ra6f0YGtg0OhEaQa/t3Q+q1MEHhWJhqQVuO5amYXQpy8MDPNoJYk+FWA
# hePP5LxwcSge5aen+f5Q6WNPd6EDxGzotvVpNi5ve0H97S3F7C/axDfKxyNh21MG
# 0W8Sb0vxi/vorcLHOL9i+t2D6yvvDzLlEefUCbQV/zGCBjXGlYJcUj6RAzXyeNAN
# xSpKXAGd7Fh+ocGHPPphcD9LQTOJgG7Y7aYztHqBLJiQQ4eAgZNU4ac6+8LnEGAL
# go1ydC5BJEuJQjYKbNTy959HrKSu7LO3Ws0w8jw6pYdC1IMpdTkk2puTgY2PDNzB
# tLM4evG7FYer3WX+8t1UMYNTAgMBAAGjggFzMIIBbzAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQURxxxNPIEPGSO8kqz+bgCAQWGXsEw
# RQYDVR0RBD4wPKQ6MDgxHjAcBgNVBAsTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEW
# MBQGA1UEBRMNMjMwMDEyKzUwMTgyNjAfBgNVHSMEGDAWgBRIbmTlUAXTgqoXNzci
# tW2oynUClTBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3JsMGEG
# CCsGAQUFBwEBBFUwUzBRBggrBgEFBQcwAoZFaHR0cDovL3d3dy5taWNyb3NvZnQu
# Y29tL3BraW9wcy9jZXJ0cy9NaWNDb2RTaWdQQ0EyMDExXzIwMTEtMDctMDguY3J0
# MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggIBAISxFt/zR2frTFPB45Yd
# mhZpB2nNJoOoi+qlgcTlnO4QwlYN1w/vYwbDy/oFJolD5r6FMJd0RGcgEM8q9TgQ
# 2OC7gQEmhweVJ7yuKJlQBH7P7Pg5RiqgV3cSonJ+OM4kFHbP3gPLiyzssSQdRuPY
# 1mIWoGg9i7Y4ZC8ST7WhpSyc0pns2XsUe1XsIjaUcGu7zd7gg97eCUiLRdVklPmp
# XobH9CEAWakRUGNICYN2AgjhRTC4j3KJfqMkU04R6Toyh4/Toswm1uoDcGr5laYn
# TfcX3u5WnJqJLhuPe8Uj9kGAOcyo0O1mNwDa+LhFEzB6CB32+wfJMumfr6degvLT
# e8x55urQLeTjimBQgS49BSUkhFN7ois3cZyNpnrMca5AZaC7pLI72vuqSsSlLalG
# OcZmPHZGYJqZ0BacN274OZ80Q8B11iNokns9Od348bMb5Z4fihxaBWebl8kWEi2O
# PvQImOAeq3nt7UWJBzJYLAGEpfasaA3ZQgIcEXdD+uwo6ymMzDY6UamFOfYqYWXk
# ntxDGu7ngD2ugKUuccYKJJRiiz+LAUcj90BVcSHRLQop9N8zoALr/1sJuwPrVAtx
# HNEgSW+AKBqIxYWM4Ev32l6agSUAezLMbq5f3d8x9qzT031jMDT+sUAoCw0M5wVt
# CUQcqINPuYjbS1WgJyZIiEkBMIIHejCCBWKgAwIBAgIKYQ6Q0gAAAAAAAzANBgkq
# hkiG9w0BAQsFADCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5
# IDIwMTEwHhcNMTEwNzA4MjA1OTA5WhcNMjYwNzA4MjEwOTA5WjB+MQswCQYDVQQG
# EwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQg
# Q29kZSBTaWduaW5nIFBDQSAyMDExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAq/D6chAcLq3YbqqCEE00uvK2WCGfQhsqa+laUKq4BjgaBEm6f8MMHt03
# a8YS2AvwOMKZBrDIOdUBFDFC04kNeWSHfpRgJGyvnkmc6Whe0t+bU7IKLMOv2akr
# rnoJr9eWWcpgGgXpZnboMlImEi/nqwhQz7NEt13YxC4Ddato88tt8zpcoRb0Rrrg
# OGSsbmQ1eKagYw8t00CT+OPeBw3VXHmlSSnnDb6gE3e+lD3v++MrWhAfTVYoonpy
# 4BI6t0le2O3tQ5GD2Xuye4Yb2T6xjF3oiU+EGvKhL1nkkDstrjNYxbc+/jLTswM9
# sbKvkjh+0p2ALPVOVpEhNSXDOW5kf1O6nA+tGSOEy/S6A4aN91/w0FK/jJSHvMAh
# dCVfGCi2zCcoOCWYOUo2z3yxkq4cI6epZuxhH2rhKEmdX4jiJV3TIUs+UsS1Vz8k
# A/DRelsv1SPjcF0PUUZ3s/gA4bysAoJf28AVs70b1FVL5zmhD+kjSbwYuER8ReTB
# w3J64HLnJN+/RpnF78IcV9uDjexNSTCnq47f7Fufr/zdsGbiwZeBe+3W7UvnSSmn
# Eyimp31ngOaKYnhfsi+E11ecXL93KCjx7W3DKI8sj0A3T8HhhUSJxAlMxdSlQy90
# lfdu+HggWCwTXWCVmj5PM4TasIgX3p5O9JawvEagbJjS4NaIjAsCAwEAAaOCAe0w
# ggHpMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRIbmTlUAXTgqoXNzcitW2o
# ynUClTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMCAYYwDwYD
# VR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBRyLToCMZBDuRQFTuHqp8cx0SOJNDBa
# BgNVHR8EUzBRME+gTaBLhklodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2Ny
# bC9wcm9kdWN0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3JsMF4GCCsG
# AQUFBwEBBFIwUDBOBggrBgEFBQcwAoZCaHR0cDovL3d3dy5taWNyb3NvZnQuY29t
# L3BraS9jZXJ0cy9NaWNSb29DZXJBdXQyMDExXzIwMTFfMDNfMjIuY3J0MIGfBgNV
# HSAEgZcwgZQwgZEGCSsGAQQBgjcuAzCBgzA/BggrBgEFBQcCARYzaHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraW9wcy9kb2NzL3ByaW1hcnljcHMuaHRtMEAGCCsG
# AQUFBwICMDQeMiAdAEwAZQBnAGEAbABfAHAAbwBsAGkAYwB5AF8AcwB0AGEAdABl
# AG0AZQBuAHQALiAdMA0GCSqGSIb3DQEBCwUAA4ICAQBn8oalmOBUeRou09h0ZyKb
# C5YR4WOSmUKWfdJ5DJDBZV8uLD74w3LRbYP+vj/oCso7v0epo/Np22O/IjWll11l
# hJB9i0ZQVdgMknzSGksc8zxCi1LQsP1r4z4HLimb5j0bpdS1HXeUOeLpZMlEPXh6
# I/MTfaaQdION9MsmAkYqwooQu6SpBQyb7Wj6aC6VoCo/KmtYSWMfCWluWpiW5IP0
# wI/zRive/DvQvTXvbiWu5a8n7dDd8w6vmSiXmE0OPQvyCInWH8MyGOLwxS3OW560
# STkKxgrCxq2u5bLZ2xWIUUVYODJxJxp/sfQn+N4sOiBpmLJZiWhub6e3dMNABQam
# ASooPoI/E01mC8CzTfXhj38cbxV9Rad25UAqZaPDXVJihsMdYzaXht/a8/jyFqGa
# J+HNpZfQ7l1jQeNbB5yHPgZ3BtEGsXUfFL5hYbXw3MYbBL7fQccOKO7eZS/sl/ah
# XJbYANahRr1Z85elCUtIEJmAH9AAKcWxm6U/RXceNcbSoqKfenoi+kiVH6v7RyOA
# 9Z74v2u3S5fi63V4GuzqN5l5GEv/1rMjaHXmr/r8i+sLgOppO6/8MO0ETI7f33Vt
# Y5E90Z1WTk+/gFcioXgRMiF670EKsT/7qMykXcGhiJtXcVZOSEXAQsmbdlsKgEhr
# /Xmfwb1tbWrJUnMTDXpQzTGCGg0wghoJAgEBMIGVMH4xCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNp
# Z25pbmcgUENBIDIwMTECEzMAAAOvMEAOTKNNBUEAAAAAA68wDQYJYIZIAWUDBAIB
# BQCgga4wGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIOS1wUPlAk3dF72Oj+a11WnC
# VyoUpIJXnWJtbyhvxqlYMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8A
# cwBvAGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEB
# BQAEggEApcSc5/aRJ4ooLt26Tkesb4cLAELZIOs9Dipr5HotTWdyZ/YRpEcYhwnE
# 8QLtaWaJijAVWx8Zw9uiPBmIlNe7lTrJR4/t9lJfiG52DWGnt10yeb+rk2VdZddp
# Ytx085B/zjrpTkHkSjh8mGXb2P8PxSUApwdCbgTexptKniQ3KKCsx7qTl03wqezk
# H5ZRX4xjkRb8B2iN/d+Qjup0jZTsZccPSz6R/XSLjn+Tw9dBYlLN/v948nsZSIGu
# SgOcR4Ayp4l6vLIVqY6IDvrIhGIy42Q69OYpe5ElhU9l1I5teaev1SsFbeScFIa3
# jphnm5uck3KSKv2ZVhxGwK5tlbOiaaGCF5cwgheTBgorBgEEAYI3AwMBMYIXgzCC
# F38GCSqGSIb3DQEHAqCCF3AwghdsAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFSBgsq
# hkiG9w0BCRABBKCCAUEEggE9MIIBOQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFl
# AwQCAQUABCAe05ZUJJMrFrmb2YaS6DyIsq3XcfAtW82JvWvhImewCAIGZmri/Jj/
# GBMyMDI0MDYyMDEwMTUyOS4yNjNaMASAAgH0oIHRpIHOMIHLMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1l
# cmljYSBPcGVyYXRpb25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0w
# NUUwLUQ5NDcxJTAjBgNVBAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2Wg
# ghHtMIIHIDCCBQigAwIBAgITMwAAAecujy+TC08b6QABAAAB5zANBgkqhkiG9w0B
# AQsFADB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDAeFw0yMzEyMDYxODQ1
# MTlaFw0yNTAzMDUxODQ1MTlaMIHLMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2Fz
# aGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENv
# cnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRpb25z
# MScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046OTIwMC0wNUUwLUQ5NDcxJTAjBgNV
# BAMTHE1pY3Jvc29mdCBUaW1lLVN0YW1wIFNlcnZpY2UwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQDCV58v4IuQ659XPM1DtaWMv9/HRUC5kdiEF89YBP6/
# Rn7kjqMkZ5ESemf5Eli4CLtQVSefRpF1j7S5LLKisMWOGRaLcaVbGTfcmI1vMRJ1
# tzMwCNIoCq/vy8WH8QdV1B/Ab5sK+Q9yIvzGw47TfXPE8RlrauwK/e+nWnwMt060
# akEZiJJz1Vh1LhSYKaiP9Z23EZmGETCWigkKbcuAnhvh3yrMa89uBfaeHQZEHGQq
# dskM48EBcWSWdpiSSBiAxyhHUkbknl9PPztB/SUxzRZjUzWHg9bf1mqZ0cIiAWC0
# EjK7ONhlQfKSRHVLKLNPpl3/+UL4Xjc0Yvdqc88gOLUr/84T9/xK5r82ulvRp2A8
# /ar9cG4W7650uKaAxRAmgL4hKgIX5/0aIAsbyqJOa6OIGSF9a+DfXl1LpQPNKR79
# 2scF7tjD5WqwIuifS9YUiHMvRLjjKk0SSCV/mpXC0BoPkk5asfxrrJbCsJePHSOE
# blpJzRmzaP6OMXwRcrb7TXFQOsTkKuqkWvvYIPvVzC68UM+MskLPld1eqdOOMK7S
# bbf2tGSZf3+iOwWQMcWXB9gw5gK3AIYK08WkJJuyzPqfitgubdRCmYr9CVsNOuW+
# wHDYGhciJDF2LkrjkFUjUcXSIJd9f2ssYitZ9CurGV74BQcfrxjvk1L8jvtN7mul
# IwIDAQABo4IBSTCCAUUwHQYDVR0OBBYEFM/+4JiAnzY4dpEf/Zlrh1K73o9YMB8G
# A1UdIwQYMBaAFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMF8GA1UdHwRYMFYwVKBSoFCG
# Tmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUy
# MFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNybDBsBggrBgEFBQcBAQRgMF4w
# XAYIKwYBBQUHMAKGUGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2Vy
# dHMvTWljcm9zb2Z0JTIwVGltZS1TdGFtcCUyMFBDQSUyMDIwMTAoMSkuY3J0MAwG
# A1UdEwEB/wQCMAAwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwDgYDVR0PAQH/BAQD
# AgeAMA0GCSqGSIb3DQEBCwUAA4ICAQB0ofDbk+llWi1cC6nsfie5Jtp09o6b6ARC
# pvtDPq2KFP+hi+UNNP7LGciKuckqXCmBTFIhfBeGSxvk6ycokdQr3815pEOaYWTn
# HvQ0+8hKy86r1F4rfBu4oHB5cTy08T4ohrG/OYG/B/gNnz0Ol6v7u/qEjz48zXZ6
# ZlxKGyZwKmKZWaBd2DYEwzKpdLkBxs6A6enWZR0jY+q5FdbV45ghGTKgSr5ECAOn
# LD4njJwfjIq0mRZWwDZQoXtJSaVHSu2lHQL3YHEFikunbUTJfNfBDLL7Gv+sTmRi
# DZky5OAxoLG2gaTfuiFbfpmSfPcgl5COUzfMQnzpKfX6+FkI0QQNvuPpWsDU8sR+
# uni2VmDo7rmqJrom4ihgVNdLaMfNUqvBL5ZiSK1zmaELBJ9a+YOjE5pmSarW5sGb
# n7iVkF2W9JQIOH6tGWLFJS5Hs36zahkoHh8iD963LeGjZqkFusKaUW72yMj/yxTe
# GEDOoIr35kwXxr1Uu+zkur2y+FuNY0oZjppzp95AW1lehP0xaO+oBV1XfvaCur/B
# 5PVAp2xzrosMEUcAwpJpio+VYfIufGj7meXcGQYWA8Umr8K6Auo+Jlj8IeFS6lSv
# KhqQpmdBzAMGqPOQKt1Ow3ZXxehK7vAiim3ZiALlM0K546k0sZrxdZPgpmz7O8w9
# gHLuyZAQezCCB3EwggVZoAMCAQICEzMAAAAVxedrngKbSZkAAAAAABUwDQYJKoZI
# hvcNAQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# MjAwBgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAy
# MDEwMB4XDTIxMDkzMDE4MjIyNVoXDTMwMDkzMDE4MzIyNVowfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoIC
# AQDk4aZM57RyIQt5osvXJHm9DtWC0/3unAcH0qlsTnXIyjVX9gF/bErg4r25Phdg
# M/9cT8dm95VTcVrifkpa/rg2Z4VGIwy1jRPPdzLAEBjoYH1qUoNEt6aORmsHFPPF
# dvWGUNzBRMhxXFExN6AKOG6N7dcP2CZTfDlhAnrEqv1yaa8dq6z2Nr41JmTamDu6
# GnszrYBbfowQHJ1S/rboYiXcag/PXfT+jlPP1uyFVk3v3byNpOORj7I5LFGc6XBp
# Dco2LXCOMcg1KL3jtIckw+DJj361VI/c+gVVmG1oO5pGve2krnopN6zL64NF50Zu
# yjLVwIYwXE8s4mKyzbnijYjklqwBSru+cakXW2dg3viSkR4dPf0gz3N9QZpGdc3E
# XzTdEonW/aUgfX782Z5F37ZyL9t9X4C626p+Nuw2TPYrbqgSUei/BQOj0XOmTTd0
# lBw0gg/wEPK3Rxjtp+iZfD9M269ewvPV2HM9Q07BMzlMjgK8QmguEOqEUUbi0b1q
# GFphAXPKZ6Je1yh2AuIzGHLXpyDwwvoSCtdjbwzJNmSLW6CmgyFdXzB0kZSU2LlQ
# +QuJYfM2BjUYhEfb3BvR/bLUHMVr9lxSUV0S2yW6r1AFemzFER1y7435UsSFF5PA
# PBXbGjfHCBUYP3irRbb1Hode2o+eFnJpxq57t7c+auIurQIDAQABo4IB3TCCAdkw
# EgYJKwYBBAGCNxUBBAUCAwEAATAjBgkrBgEEAYI3FQIEFgQUKqdS/mTEmr6CkTxG
# NSnPEP8vBO4wHQYDVR0OBBYEFJ+nFV0AXmJdg/Tl0mWnG1M1GelyMFwGA1UdIARV
# MFMwUQYMKwYBBAGCN0yDfQEBMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTATBgNVHSUEDDAK
# BggrBgEFBQcDCDAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMC
# AYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvX
# zpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20v
# cGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYI
# KwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDANBgkqhkiG
# 9w0BAQsFAAOCAgEAnVV9/Cqt4SwfZwExJFvhnnJL/Klv6lwUtj5OR2R4sQaTlz0x
# M7U518JxNj/aZGx80HU5bbsPMeTCj/ts0aGUGCLu6WZnOlNN3Zi6th542DYunKmC
# VgADsAW+iehp4LoJ7nvfam++Kctu2D9IdQHZGN5tggz1bSNU5HhTdSRXud2f8449
# xvNo32X2pFaq95W2KFUn0CS9QKC/GbYSEhFdPSfgQJY4rPf5KYnDvBewVIVCs/wM
# nosZiefwC2qBwoEZQhlSdYo2wh3DYXMuLGt7bj8sCXgU6ZGyqVvfSaN0DLzskYDS
# PeZKPmY7T7uG+jIa2Zb0j/aRAfbOxnT99kxybxCrdTDFNLB62FD+CljdQDzHVG2d
# Y3RILLFORy3BFARxv2T5JL5zbcqOCb2zAVdJVGTZc9d/HltEAY5aGZFrDZ+kKNxn
# GSgkujhLmm77IVRrakURR6nxt67I6IleT53S0Ex2tVdUCbFpAUR+fKFhbHP+Crvs
# QWY9af3LwUFJfn6Tvsv4O+S3Fb+0zj6lMVGEvL8CwYKiexcdFYmNcP7ntdAoGokL
# jzbaukz5m/8K6TT4JDVnK+ANuOaMmdbhIurwJ0I9JZTmdHRbatGePu1+oDEzfbzL
# 6Xu/OHBE0ZDxyKs6ijoIYn/ZcGNTTY3ugm2lBRDBcQZqELQdVTNYs6FwZvKhggNQ
# MIICOAIBATCB+aGB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEn
# MCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjkyMDAtMDVFMC1EOTQ3MSUwIwYDVQQD
# ExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloiMKAQEwBwYFKw4DAhoDFQCz
# cgTnGasSwe/dru+cPe1NF/vwQ6CBgzCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1w
# IFBDQSAyMDEwMA0GCSqGSIb3DQEBCwUAAgUA6h3yoDAiGA8yMDI0MDYyMDAwMTMy
# MFoYDzIwMjQwNjIxMDAxMzIwWjB3MD0GCisGAQQBhFkKBAExLzAtMAoCBQDqHfKg
# AgEAMAoCAQACAiblAgH/MAcCAQACAhPdMAoCBQDqH0QgAgEAMDYGCisGAQQBhFkK
# BAIxKDAmMAwGCisGAQQBhFkKAwKgCjAIAgEAAgMHoSChCjAIAgEAAgMBhqAwDQYJ
# KoZIhvcNAQELBQADggEBAAsoNiURR7leeakwG3L0j5KGQ32BqqSMd6QnJ0wcnjQE
# exx/lzsMDtx/KAGGM+rCHlgOpCFkQWJbzUI9NKgyUVlN4lJGtxx72asLO0/9qZ1v
# ly7EAeXoe8kst480wL4x2gCzI9zMsnBarLM0+w2XOK4rw8cWFsJ2LP6ogum/JoVp
# vZp70Jghcznsq67v7C4C8VeEj1AgQo44TzkUsJHI6LQ2G+qL98SAkJZzaEBNCqBW
# 6jFNyi8UKA4qr4PAKKSuFRy/A8GOBSsJ9LfcrdpYJe3ZpBkllQiT67ufqP0DmHzB
# DygV7sZXDYF/vRvxkIF0Gc7+xzQVDVCZn8WNSXNGq10xggQNMIIECQIBATCBkzB8
# MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVk
# bW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1N
# aWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMAITMwAAAecujy+TC08b6QABAAAB
# 5zANBglghkgBZQMEAgEFAKCCAUowGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEE
# MC8GCSqGSIb3DQEJBDEiBCDRJ8GIN3puD8Z7TQlWuSAUtz0TjJHBF1jev4NV43On
# vjCB+gYLKoZIhvcNAQkQAi8xgeowgecwgeQwgb0EIOU2XQ12aob9DeDFXM9UFHeE
# X74Fv0ABvQMG7qC51nOtMIGYMIGApH4wfDELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENB
# IDIwMTACEzMAAAHnLo8vkwtPG+kAAQAAAecwIgQgM6j0Ey53PvixqrwxlDyYzh1E
# OoVlERoE5F6Vxis5PyEwDQYJKoZIhvcNAQELBQAEggIAsOLCt5KmHIMF8ie4bxY7
# 7DR+K4NnJV5eQeE9RmKpz2WljdNQOs7tAl1QXJkOieY/6pUvVnAKaoVlXmRwj6v6
# ozsz7C68jJmQzRg53mxlTjX2A4RG9zMDEgRNTMjRKzboYAQS1YlXqgkVMBp8oCni
# /f3T/8mikmOBeIJfNKWfo097rkGwHnfshSaEWfIXpp2qxS1S22x5ypjoP2hLDP3Z
# vAwma8H0vbOIKtQ1Gp+GW9/u61whyKABz8l5ssRLS6QRlHIvYXBId5oqkRU+jdOc
# w83rb4SDaUQ+/zYhkJBOXcjEZT9PPxPtkXDbw+gyViOx1+Gkw6j/bG5de9LMv+BV
# emknJ4CzoCTa1Mp3TZVpIfwyJ+hYGMeZmNiOt2rfeNuplcLxG2lA4eEiFbs14WeY
# Auk/IQKdH9k6EZe/AyjBdANbloCZMW3Os2JqjRNpEgi0QssaRPT/qxyk9dFLXQ20
# COehtRqsZD4oANFEJisqq/v3KElpCFDfiikUs8C7LJt2Y3L/LePl6GKgnDuNF7SN
# vqhKKqZKCSHC4glCilr3as/dS194CDdI6pQ7V4ps2GlrgCannehnuKHwDPGOVnWQ
# RTY4aQNg80PUEucj8tVq3h/pwSe3JKS9SBvXH/V09enKTOFd74kZIUIm/zpXIMvy
# KKTyoDgWmQAN7QFCKz+U7ME=
# SIG # End signature block
