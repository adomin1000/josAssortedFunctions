#
# Module manifest for module 'ADDRS'
#
# Generated by: Jos Lieben
#
# Generated on: 5/16/2022
#

@{

# Script module or binary module file associated with this manifest.
RootModule = 'ADDRS.psm1'

# Version number of this module.
ModuleVersion = '1.0.2'

# Supported PSEditions
# CompatiblePSEditions = @()

# ID used to uniquely identify this module
GUID = 'bbd6707a-392d-4db8-97c3-2634f029e2f0'

# Author of this module
Author = 'Jos Lieben'

# Company or vendor of this module
CompanyName = 'Lieben Consultancy'

# Copyright statement for this module
Copyright = 'https://www.lieben.nu/liebensraum/commercial-use/ (Commercial (re)use not allowed without prior written consent by the author, otherwise free to use/modify as long as header are kept intact)'

# Description of the functionality provided by this module
Description = 'Automatically right sizes any Azure Windows VM based on configurable telemetry data to the optimal size based on cpu/mem, performance rating and cost'

# Minimum version of the Windows PowerShell engine required by this module
PowerShellVersion = '4.0'

# Name of the Windows PowerShell host required by this module
# PowerShellHostName = ''

# Minimum version of the Windows PowerShell host required by this module
# PowerShellHostVersion = ''

# Minimum version of Microsoft .NET Framework required by this module. This prerequisite is valid for the PowerShell Desktop edition only.
# DotNetFrameworkVersion = ''

# Minimum version of the common language runtime (CLR) required by this module. This prerequisite is valid for the PowerShell Desktop edition only.
# CLRVersion = ''

# Processor architecture (None, X86, Amd64) required by this module
# ProcessorArchitecture = ''

# Modules that must be imported into the global environment prior to importing this module
RequiredModules = @("Az.Compute","Az.OperationalInsights","Az.Resources","Az.Accounts")

# Assemblies that must be loaded prior to importing this module
# RequiredAssemblies = @()

# Script files (.ps1) that are run in the caller's environment prior to importing this module.
# ScriptsToProcess = @()

# Type files (.ps1xml) to be loaded when importing this module
# TypesToProcess = @()

# Format files (.ps1xml) to be loaded when importing this module
# FormatsToProcess = @()

# Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
# NestedModules = @()

# Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export.
FunctionsToExport = '*'

# Cmdlets to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no cmdlets to export.
CmdletsToExport = '*'

# Variables to export from this module
VariablesToExport = '*'

# Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no aliases to export.
AliasesToExport = @()

# DSC resources to export from this module
# DscResourcesToExport = @()

# List of all modules packaged with this module
# ModuleList = @()

# List of all files packaged with this module
# FileList = @()

# Private data to pass to the module specified in RootModule/ModuleToProcess. This may also contain a PSData hashtable with additional module metadata used by PowerShell.
PrivateData = @{

    PSData = @{

        # Tags applied to this module. These help with module discovery in online galleries.
        Tags = @("Azure","Rightsizing","VirtualMachines","Costoptimization","Performancemonitoring")

        # A URL to the license for this module.
        LicenseUri = 'https://www.lieben.nu/liebensraum/commercial-use'

        # A URL to the main website for this project.
        ProjectUri = 'https://www.lieben.nu/liebensraum/2022/05/automatic-modular-rightsizing-of-azure-vms-with-special-focus-on-azure-virtual-desktop/'

        # A URL to an icon representing this module.
        # IconUri = ''

        # ReleaseNotes of this module
        # ReleaseNotes = ''

    } # End of PSData hashtable

} # End of PrivateData hashtable

# HelpInfo URI of this module
HelpInfoURI = 'https://www.lieben.nu/liebensraum/2022/05/automatic-modular-rightsizing-of-azure-vms-with-special-focus-on-azure-virtual-desktop/'

# Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix.
# DefaultCommandPrefix = ''

}

