#
# Module manifest for TXTRecords
# Submodule of Palimpsest
#

@{
    RootModule        = 'TXTRecords.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a3f2e7c1-84b0-4d2f-9e3a-1c6f8b2d5a07'
    Author            = 'TXTRecords'
    Description       = 'Store and retrieve binary files via Cloudflare DNS TXT records.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Set-CFCredential'
        'Get-CFZone'
        'Publish-TXTRecord'
        'Get-TXTRecord'
        'Get-TXTRecordBytes'
        'Remove-TXTRecord'
        'Get-TXTRecordList'
        'Publish-TXTStripe'
        'Get-TXTStripeBytes'
        'Get-TXTStripe'
        'Remove-TXTStripe'
        'Get-TXTStripeList'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @('DNS', 'Cloudflare', 'TXT', 'Binary', 'Steganography')
        }
    }
}
