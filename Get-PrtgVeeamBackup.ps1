<#
.SYNOPSIS
Retrieves information about your Veeam Backup jobs in PRTG compatible format

.DESCRIPTION
The Get-PrtgVeeamBackup.ps1 uses the PowerShell module by Veeam Software, installed on your Veeam Backup server to retrieve information about your backup jobs. 
The XML output can be used as PRTG custom sensor.

.PARAMETER ComputerName
The name of the Veeam server, the script connects to. This server must have the Veeam PowerShell extensions to be installed.

.EXAMPLE
Retrieves status information about you Veeam Backup jobs from server "MyVeeamServer"
Get-PrtgVeeamBackup.ps1 -ComputerName MyVeeamServer.domain.tld

.NOTES
PowerShell remoting must be enabled on the target machine and the Veeam PowerShell extensions must be installed on it (not the probe server).
Detailed information on the Veeam PowerShell snaping can be found here: https://hyperv.veeam.com/blog/how-to-use-veeam-powershell-snap-in-hyper-v-backup/

Author:  Marc Debold
Version: 1.1
Version History:
    1.1  31.10.2016  Complete rewrite
    1.0  16.10.2016  Initial release
.LINK
http://www.team-debold.de/###TBD###
#>

[cmdletbinding()] Param(
    [Parameter(Mandatory=$true, Position=1)][string] $ComputerName,
    [Parameter(Mandatory=$false, Position=2)][string[]] $ExcludeNamePattern = $null
)

<# Function to raise error in PRTG style and stop script #>
function New-PrtgError {
    [CmdletBinding()] param(
        [Parameter(Position=0)][string] $ErrorText
    )

    Write-Host "<PRTG>
    <Error>1</Error>
    <Text>$ErrorText</Text>
</PRTG>"
    Exit
}

function Out-Prtg {
    [CmdletBinding()] param(
        [Parameter(Position=0, Mandatory=$true, ValueFromPipeline=$true)][array] $MonitoringData
    )
    # Create output for PRTG
    $XmlDocument = New-Object System.XML.XMLDocument
    $XmlRoot = $XmlDocument.CreateElement("PRTG")
    $XmlDocument.appendChild($XmlRoot) | Out-Null
    # Cycle through outer array
    foreach ($Result in $MonitoringData) {
        # Create result-node
        $XmlResult = $XmlRoot.appendChild(
            $XmlDocument.CreateElement("Result")
        )
        # Cycle though inner hashtable
        $Result.GetEnumerator() | ForEach-Object {
            # Use key of hashtable as XML element
            $XmlKey = $XmlDocument.CreateElement($_.key)
            $XmlKey.AppendChild(
                # Use value of hashtable as XML textnode
                $XmlDocument.CreateTextNode($_.value)    
            ) | Out-Null
            $XmlResult.AppendChild($XmlKey) | Out-Null
        }
    }
    # Format XML output
    $StringWriter = New-Object System.IO.StringWriter 
    $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
    $XmlWriter.Formatting = "indented"
    $XmlWriter.Indentation = 1
    $XmlWriter.IndentChar = "`t" 
    $XmlDocument.WriteContentTo($XmlWriter) 
    $XmlWriter.Flush() 
    $StringWriter.Flush() 
    Return $StringWriter.ToString() 
}

try {
    $VeeamStatus = Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
        Add-PSSnapin VeeamPSSnapin
        $ResProps = @{
            "BuLastResult" = @{
                "None" = 0; "Success" = 0; "Warning" = 0; "Failed" = 0
            };
            "BuRunning" = 0;
            "BuDuration" = 0;
            "BuJobsTotal" = 0
        }
        $Results = New-Object -TypeName psobject -Property $ResProps

        # Get backup jobs
        $Jobs = Get-VBRJob -WarningAction SilentlyContinue | ? { 
            $_.IsBackup -and 
            $_.IsScheduleEnabled -and -not ($_.Name -like "*test*" -or $_.Name -like "*temp*" -or $_.Name -like "*old*")
        } | Select-Object IsRunning, @{Name="LastStatus"; Expression={$_.GetLastResult()}}, @{Name="Duration"; Expression={$_.FindLastSession().EndTime - $_.FindLastSession().CreationTime}}
        foreach ($Job in $Jobs) {
            switch ($Job.LastStatus) {
                "None"      { $Results.BuLastResult.None++ }
                "Success"   { $Results.BuLastResult.Success++ }
                "Warning"   { $Results.BuLastResult.Warning++ }
                "Failed"    { $Results.BuLastResult.Failed++ }
            }
            $Results.BuJobsTotal++
            if ($Job.IsRunning) {
                $Results.BuRunning++
            } else {
                $Results.BuDuration += $Job.Duration.TotalMinutes
            }
        }
        if ($Results.BuDuration -gt 0) {
            $Results.BuDuration = $Results.BuDuration / ($Results.BuLastResult.Success + $Results.BuLastResult.Warning + $Results.BuLastResult.Failed)
        }
        Return $Results
    }
} catch {
    New-PrtgError -ErrorText "Request to target server $($ComputerName) failed"
}
# Compose information for XML output
$Result = @(
    @{
        Channel = "Total Jobs";
        Value = $VeeamStatus.BuJobsTotal
    },
    @{
        Channel = "Currently Running Jobs";
        Value = $VeeamStatus.BuRunning
    },
    @{
        Channel = "Average Job Runtime (min)";
        Value = $VeeamStatus.BuDuration.ToString('f2', (New-Object System.Globalization.CultureInfo('en-US')));
        Float = 1;
        DecimalMode = 2;
        Unit = "Custom";
        CustomUnit = "Min."
    },
    @{
        Channel = "Job Status: Success";
        Value = $VeeamStatus.BuLastResult.Success
    },
    @{
        Channel = "Job Status: Failed";
        Value = $VeeamStatus.BuLastResult.Failed;
        LimitMode = 1;
        LimitMaxError = 0.5
    },
    @{
        Channel = "Job Status: None";
        Value = $VeeamStatus.BuLastResult.None
    }
)
Out-Prtg -MonitoringData $Result